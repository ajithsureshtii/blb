# Migration Plan: SEAL → OpenFHE in BLB BERT Inference

## Overview

The goal is to replace Microsoft SEAL with OpenFHE as the FHE backend inside BLB,
while keeping the MPC layer (SCI, FPMath, OT) completely untouched.

The strategy is **component-by-component replacement with tests at each stage**.
Nothing gets wired into the main BERT pipeline until its isolated component passes tests.
Once all components are individually verified, the final integration replaces `he.h` / `he.cpp`
and the call sites in `ckks_bert.cpp` / `linear_ckks.cpp`.

---

## Guiding Principles

- **Never break MPC.** The `FixArray` / `FPMath` / `IOPack` stack is not touched.
- **Test in isolation first.** Each component gets a standalone test before integration.
- **Numerical equivalence is the bar.** OpenFHE outputs must match SEAL outputs to within
  the expected fixed-point precision (typically ±2^{-10} at scale 2^43).
- **Keep SEAL around until the end.** Run SEAL and OpenFHE side-by-side during testing.
- **One HE_CKKS instance at a time.** Validate `he1` end-to-end before touching `he2`.

---

## Repository Layout (Proposed)

```
SCI/
└── src/
    └── LinearHE/
        ├── he.h                  ← SEAL version (current, untouched until Phase 6)
        ├── he_openfhe.h          ← new OpenFHE wrapper (built phase by phase)
        ├── he_openfhe.cpp
        └── tests/
            ├── test_context.cpp
            ├── test_keygen.cpp
            ├── test_encode_encrypt.cpp
            ├── test_evaluator_ops.cpp
            ├── test_rotation.cpp
            ├── test_fft_ntt.cpp
            ├── test_mpc_fhe_boundary.cpp
            ├── test_linear_layer.cpp
            └── test_bert_block.cpp
```

---

## Phase 0 — Environment & Build Setup

**Goal:** Confirm OpenFHE builds and links cleanly alongside BLB's existing build system.

### Tasks

- [ ] Add OpenFHE as an include/lib path in `SCI/CMakeLists.txt` (or equivalent)
  - OpenFHE install prefix: `../../../openfhe-development/build/` (relative to blb-fork root)
  - Link targets: `OPENFHEpke`, `OPENFHEcore`, `OPENFHEbinfhe`
- [ ] Write a minimal `test_context.cpp` that creates a CKKS CryptoContext and exits cleanly
- [ ] Confirm no symbol conflicts between SEAL and OpenFHE (they can coexist if namespaced correctly)
- [ ] Confirm OpenFHE version: check `openfhe-development/CMakeLists.txt` for version tag

### Test: `test_context.cpp`

```cpp
// Passes if: compiles, links, runs, prints parameter summary without crash
#include "openfhe.h"
using namespace lbcrypto;

int main() {
    CCParams<CryptoContextCKKSRNS> params;
    params.SetMultiplicativeDepth(6);
    params.SetScalingModSize(44);
    params.SetBatchSize(16384);
    params.SetSecurityLevel(HEStd_128_classic);
    auto cc = GenCryptoContext(params);
    cc->Enable(PKE);
    cc->Enable(KEYSWITCH);
    cc->Enable(LEVELEDSHE);
    std::cout << "Slots: " << cc->GetEncodingParams()->GetBatchSize() << std::endl;
    return 0;
}
```

**Pass criterion:** Prints correct slot count, matches `poly_modulus_degree / 2`.

---

## Phase 1 — Context + Key Generation

**Goal:** Replicate the four `HE_CKKS` constructor calls (he1–he4) using OpenFHE parameters.

### SEAL → OpenFHE Parameter Mapping

| BLB Instance | SEAL Params | OpenFHE Equivalent |
|---|---|---|
| `he1` | degree=32768, moduli={60,34,60,60,60,60,60}, scale=2^44 | `SetRingDim(32768)`, `SetScalingModSize(44)`, `SetFirstModSize(60)`, depth=6 |
| `he2` | degree=32768, moduli={60,60,60,60,60,60,60}, scale=2^43 | `SetRingDim(32768)`, `SetScalingModSize(43)`, depth=6 |
| `he3` | degree=32768, moduli={60,32,60,60,60,60,60,60}, scale=2^46 | `SetRingDim(32768)`, `SetScalingModSize(46)`, depth=7 |
| `he4` | degree=16384, moduli={60,34,60,60,60}, scale=2^38 | `SetRingDim(16384)`, `SetScalingModSize(38)`, depth=4 |

### Key Generation Mapping

| SEAL | OpenFHE |
|------|---------|
| `keygen.secret_key()` + `create_public_key()` | `cc->KeyGen()` → returns `KeyPair` |
| `create_relin_keys()` | `cc->EvalMultKeyGen(keypair.secretKey)` |
| `create_galois_keys()` (all rotations) | `cc->EvalRotateKeyGen(keypair.secretKey, rotation_indices)` |

**Note on rotation indices:** SEAL generates keys for all rotations lazily.
OpenFHE requires explicit index list. Audit `linear_ckks.cpp` to extract every
unique rotation step used (from `rotate_vector` calls) and pass that list at key gen time.

### Test: `test_keygen.cpp`

- Create all four contexts (he1–he4 params)
- Generate keypairs, EvalMult keys, EvalRotate keys for a known index set
- Serialize keys to disk, deserialize, confirm they are functionally identical
  (encrypt a vector → decrypt → compare)

**Pass criterion:** Encrypt random vector, decrypt, max absolute error < 2^{-20}.

---

## Phase 2 — Encode, Encrypt, Decrypt

**Goal:** Replace `CKKSEncoder::encode` + `Encryptor::encrypt` + `Decryptor::decrypt`.

### API Mapping

| SEAL | OpenFHE |
|------|---------|
| `encoder->encode(values, scale, pt)` | `cc->MakeCKKSPackedPlaintext(values, 1, 0, nullptr, slots)` |
| `encryptor->encrypt(pt, ct)` | `cc->Encrypt(keypair.publicKey, pt)` |
| `decryptor->decrypt(ct, pt)` | `cc->Decrypt(keypair.secretKey, ct, &pt)` |
| `encoder->decode(pt, values)` | `pt->GetCKKSPackedValue()` |

**Important difference:** In SEAL, scale is passed at encode time.
In OpenFHE, scale is implicit from `ScalingModSize` set at context creation.
The four he instances have different scales — this must be handled by creating
four separate CryptoContexts (matching current SEAL design).

### Test: `test_encode_encrypt.cpp`

- For each of he1–he4 parameter sets:
  - Encode a known vector of 128 doubles (simulating a BERT embedding slice)
  - Encrypt → Decrypt → Decode
  - Compare against SEAL output for the same input
- Also test complex-valued encoding (used in `mpc_to_ckks`)

**Pass criterion:** Per-element absolute error < 2^{-15} (well within CKKS precision).

---

## Phase 3 — Evaluator Operations

**Goal:** Replace all `evaluator->*` calls. These are the highest-frequency FHE calls.

### API Mapping

| SEAL | OpenFHE | Notes |
|------|---------|-------|
| `evaluator->add(ct1, ct2, r)` | `cc->EvalAdd(ct1, ct2)` | |
| `evaluator->add_inplace(ct1, ct2)` | `ct1 = cc->EvalAdd(ct1, ct2)` | OpenFHE is immutable-style |
| `evaluator->add_plain_inplace(ct, pt)` | `cc->EvalAdd(ct, pt)` | |
| `evaluator->sub(ct1, ct2, r)` | `cc->EvalSub(ct1, ct2)` | |
| `evaluator->sub_inplace(ct1, ct2)` | `ct1 = cc->EvalSub(ct1, ct2)` | |
| `evaluator->multiply(ct1, ct2, r)` | `cc->EvalMult(ct1, ct2)` | includes relin in OpenFHE by default |
| `evaluator->multiply_inplace(ct1, ct2)` | `ct1 = cc->EvalMult(ct1, ct2)` | |
| `evaluator->multiply_plain_inplace(ct, pt)` | `cc->EvalMult(ct, pt)` | |
| `evaluator->relinearize_inplace(ct, rk)` | `cc->Relinearize(ct)` | often implicit after EvalMult |
| `evaluator->rescale_to_next_inplace(ct)` | `cc->ModReduce(ct)` | called "ModReduce" in OpenFHE |
| `evaluator->mod_switch_to_next_inplace(ct)` | `cc->LevelReduce(ct, nullptr, 1)` | level drop without rescale |
| `evaluator->square_inplace(ct)` | `ct = cc->EvalMult(ct, ct)` | |
| `evaluator->complex_conjugate(ct, gk, r)` | `cc->EvalAutomorphism(ct, ...)` | See note below |

**Note on `complex_conjugate`:** SEAL's `complex_conjugate` applies the conjugation
automorphism (index = 2N - 1 for degree N). In OpenFHE, this is
`cc->EvalAutomorphism(ct, poly_degree - 1, precomputed_map)` or handled via
`EvalConjugate` if available. This needs careful testing — it is used 7+ times in the
real-part extraction step of the FHE↔MPC conversion.

**Note on `EvalMult` + relin:** OpenFHE's `EvalMult(ct, ct)` automatically relinearizes
when `EvalMultKeyGen` has been called. The explicit `relinearize_inplace` calls in SEAL
may become no-ops in OpenFHE.

### Test: `test_evaluator_ops.cpp`

For each operation:
- Run both SEAL and OpenFHE on the same random inputs
- Decrypt both outputs, compare element-wise
- Test at all four scale/level configurations (he1–he4)

**Pass criterion:** Max absolute error < 2^{-10} for all ops.

---

## Phase 4 — Rotation & Conjugation

**Goal:** Replace `rotate_vector` and `complex_conjugate`. These are the most
performance-sensitive FHE calls (10+ per transformer block).

### API Mapping

| SEAL | OpenFHE |
|------|---------|
| `evaluator->rotate_vector(ct, step, gk, r)` | `cc->EvalRotate(ct, step)` |
| `evaluator->rotate_vector_inplace(ct, step, gk)` | `ct = cc->EvalRotate(ct, step)` |
| `evaluator->complex_conjugate(ct, gk, r)` | `cc->EvalConjugate(ct, keyMap)` |

**Pre-requisite:** All rotation indices used in `linear_ckks.cpp` must be registered
at key generation time (Phase 1). Extract them by grepping:
```bash
grep -n "rotate_vector" SCI/tests/bert_large_bolt/linear_ckks.cpp | grep -oP '\-?\d+' 
```

### Test: `test_rotation.cpp`

- Generate a known plaintext vector (e.g., [0,1,2,...,127] repeated to fill slots)
- Rotate by each unique step value used in BLB
- Decrypt and verify the rotation is correct
- Test conjugation: verify that conjugate of (a+bi) encoded vector gives (a-bi) after decode

**Pass criterion:** Exact slot correspondence after rotation; conjugate values within 2^{-15}.

---

## Phase 5 — Custom FFT / NTT Layer (Hardest Phase)

**Goal:** Replace the low-level SEAL internals used in the FHE↔MPC conversion functions:
`ckks_encode`, `ckks_decode`, `ckks_ntt`, `ckks_intt`.

These functions bypass SEAL's public API and directly call:
- `seal::util::ntt_negacyclic_harvey` / `inverse_ntt_negacyclic_harvey`
- `context_data.rns_tool()->base_q()->decompose()` / `compose_array()`
- `util::barrett_reduce_64/128`, `util::negate_uint_mod`
- `util::DWTHandler::transform_to_rev` / `transform_from_rev` (FFT)
- `util::ComplexRoots`

### Two options — choose one:

**Option A: Use OpenFHE's DCRTPoly internals directly**
- OpenFHE exposes `DCRTPoly::GetAllElements()` → `vector<PolyImpl<NativeVector>>`
- Each `PolyImpl` has `GetValues()` → `NativeVector` (coefficient access)
- NTT: `PolyImpl::SwitchFormat()` toggles between coefficient and evaluation form
- RNS compose/decompose: `DCRTPoly::CRTDecompose()`, `DCRTPoly::BaseDecompose()`
- Barrett reduction: available in `src/core/include/math/nbtheory.h`
- FFT: OpenFHE has its own `DiscreteFourierTransform` in `src/core/include/math/dftransfrm.h`

**Option B: Keep a standalone FFT/NTT layer independent of both SEAL and OpenFHE**
- Extract the FFT/NTT code from `he.cpp` into a self-contained `fft_utils.cpp`
- Replace only SEAL's `ComplexRoots` and `DWTHandler` with equivalent math
- Keep the RNS and NTT pipeline, rewriting only the SEAL-specific calls
- This is the **safer option** — less risk of breaking the MPC↔FHE conversion semantics

**Recommendation: Option B** for stability. Option A for performance.

### Test: `test_fft_ntt.cpp`

- `ckks_encode` round-trip: encode a vector of integers → `ckks_ntt` → `ckks_intt` → `ckks_decode` → compare to original
- Compare SEAL and OpenFHE outputs of `ckks_encode` on the same input (they should be numerically equivalent)
- Test `ring_to_field` and `field_to_ring` with known values — these depend on the NTT/RNS layer

**Pass criterion:** Round-trip reconstruction error < 2^{-10} for all 128-element vectors typical in BERT.

---

## Phase 6 — FHE ↔ MPC Boundary

**Goal:** Validate the full `mpc_to_ckks` → homomorphic ops → `ckks_to_mpc` pipeline.
This is the most critical integration test.

### What to test

```
MPC shares (FixArray, ell=37, s=12)
    → mpc_to_ckks()        [Phase 5 + Phase 2 ops]
    → encode + NTT
    → FHE linear op        [Phase 3: multiply_plain + add]
    → decrypt
    → ckks_to_mpc()        [Phase 5 + INTT + field_to_ring]
    → compare against plaintext ground truth
```

### Test: `test_mpc_fhe_boundary.cpp`

- Simulate one client party and one server party in the same process (use `party=1`/`party=2` with loopback)
- Pass a known MPC-shared vector through the full conversion cycle
- Apply a known plaintext weight matrix (one BERT Q-projection, for example)
- Verify the output MPC shares reconstruct to the expected linear layer output (< 2^{-8} error)

**Pass criterion:** The reconstructed dot product matches plaintext numpy/Python reference computation.

---

## Phase 7 — Linear Layer (BSGS Matrix Multiplication)

**Goal:** Validate `bert_cipher_plain_bsgs` and `bert_cipher_plain_bsgs_2` with OpenFHE ops.

These functions implement Baby-Step Giant-Step diagonal matrix encoding for encrypted MatMul.
They are the core of all linear layers in BERT (Q/K/V projections, FFN linear1/linear2).

### Key changes needed in `linear_ckks.cpp`

- Replace all `evaluator->rotate_vector` → `cc->EvalRotate`
- Replace all `evaluator->multiply_plain` → `cc->EvalMult`
- Replace all `evaluator->add` → `cc->EvalAdd`
- Replace `flood_ciphertext()` — noise flooding for IND-CPA security
  - OpenFHE equivalent: `cc->AddRandomNoise(ct)` if available, else manually add
    an encryption of zero with appropriate noise level

### Test: `test_linear_layer.cpp`

- Load real BERT-Base SST-2 Q-projection weights (from `weights_txt/`)
- Encode one input token embedding (128-dim slice)
- Run `bert_cipher_plain_bsgs` with OpenFHE
- Decrypt output, compare against `numpy.dot(input, weight)` reference
- Test all four linear function variants used in BLB

**Pass criterion:** Max absolute error < 2^{-8} (matching BLB's own precision spec).

---

## Phase 8 — Full Transformer Block

**Goal:** Run one complete BERT encoder block end-to-end using OpenFHE.

This replaces `transformer_block_test()` in `ckks_bert_large_main.cpp`.

### What a single block covers

1. LayerNorm Part 2 + QKV projections (he1)
2. QK^T (he1) → MPC Softmax → V projection (he2)
3. Output projection + LayerNorm (he2)
4. FFN Linear1 + GeLU (he3)
5. FFN Linear2 + ResidualAdd + LayerNorm (he4)

### Test: `test_bert_block.cpp`

- Run the two-party protocol on loopback (same machine, two threads)
- Use real BERT-Base SST-2 weights and a real tokenized input
- Compare logits against HuggingFace plaintext BERT output
- Record per-component timings (same breakdown as BLB's existing profiler)

**Pass criterion:**
- Logit error < 2% (matching BLB's accuracy spec)
- No crashes or protocol failures across 10 runs

---

## Phase 9 — Integration & Cleanup

**Goal:** Remove SEAL entirely, wire `he_openfhe.h` as the sole FHE backend.

### Steps

- [ ] Replace `#include "he.h"` with `#include "he_openfhe.h"` in all call sites
- [ ] Remove SEAL from `CMakeLists.txt`
- [ ] Run the full GLUE benchmark suite: SST-2, MRPC, RTE, STS-B
- [ ] Compare accuracy and latency numbers against original BLB SEAL results
- [ ] Update `SEAL_TO_OPENFHE_ANALYSIS.md` with final API diff notes

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| OpenFHE CKKS noise growth differs from SEAL → precision loss | Medium | High | Test at each phase; may need to adjust moduli chain |
| `complex_conjugate` semantics differ | Medium | High | Dedicated test in Phase 4 before any integration |
| Rotation key index set incomplete → runtime crash | High | Medium | Audit all rotation steps in Phase 1; generate exhaustively |
| Low-level NTT/RNS differences break FHE↔MPC conversion | High | High | Phase 5 is the critical gate — do not proceed to Phase 6 until passing |
| OpenFHE `EvalMult` implicit relin changes noise level unexpectedly | Low | Medium | Profile noise levels in Phase 3 tests |
| `flood_ciphertext` has no direct OpenFHE equivalent | Low | Low | Implement manually as encrypt(zero) + add |

---

## Suggested Development Order

```
Phase 0  (1–2 days)   Build system, confirm compilation
Phase 1  (2–3 days)   Context + key generation, serialize/deserialize
Phase 2  (1–2 days)   Encode/encrypt/decrypt round-trip
Phase 3  (3–4 days)   All evaluator ops, numerical equivalence vs SEAL
Phase 4  (2–3 days)   Rotation + conjugation (extract all indices first)
Phase 5  (5–7 days)   FFT/NTT layer — the hardest phase, budget extra time
Phase 6  (3–4 days)   FHE↔MPC boundary, two-party loopback test
Phase 7  (3–4 days)   BSGS linear layer with real BERT weights
Phase 8  (3–5 days)   Full transformer block, end-to-end
Phase 9  (1–2 days)   SEAL removal, full GLUE benchmarks

Total estimate: ~25–35 working days
```

---

## Reference Files

| What | Path |
|------|------|
| Current SEAL wrapper | `SCI/src/LinearHE/he.h`, `he.cpp` |
| FHE↔MPC conversion | `SCI/tests/bert_large_bolt/ckks_bert_basic.cpp` |
| Linear layer (BSGS) | `SCI/tests/bert_large_bolt/linear_ckks.cpp` |
| Main BERT driver | `SCI/tests/bert_large_bolt/ckks_bert_large_main.cpp` |
| OpenFHE master include | `../../../openfhe-development/src/pke/include/openfhe.h` |
| OpenFHE CKKS context | `../../../openfhe-development/src/pke/include/scheme/ckksrns/gen-cryptocontext-ckksrns.h` |
| OpenFHE DCRTPoly internals | `../../../openfhe-development/src/core/include/lattice/hal/default/dcrtpoly.h` |
| OpenFHE FFT | `../../../openfhe-development/src/core/include/math/dftransfrm.h` |
| OpenFHE CKKS example | `../../../openfhe-development/src/pke/examples/simple-ckks-bootstrapping.cpp` |
| Detailed SEAL API audit | `SEAL_TO_OPENFHE_ANALYSIS.md` |
