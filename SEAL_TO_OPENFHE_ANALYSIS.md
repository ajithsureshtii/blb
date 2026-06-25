# BLB: FHE & MPC Function Analysis
### Goal: Replace Microsoft SEAL with OpenFHE

This document is a line-level audit of every FHE and MPC function used in BLB's BERT-Base
implementation. Written to guide the SEAL → OpenFHE migration.

---

## Table of Contents

1. [FHE Parameter Setup](#1-fhe-parameter-setup)
2. [SEAL Data Structures](#2-seal-data-structures)
3. [Evaluator Operations (FHE Core)](#3-evaluator-operations-fhe-core)
4. [Encoder / Encryptor / Decryptor](#4-encoder--encryptor--decryptor)
5. [SEAL Low-Level Internals](#5-seal-low-level-internals)
6. [FHE ↔ MPC Conversion Boundaries](#6-fhe--mpc-conversion-boundaries)
7. [MPC Protocol Functions](#7-mpc-protocol-functions)
8. [BERT Operation → FHE/MPC Mapping](#8-bert-operation--fhempc-mapping)
9. [Migration Priority Table](#9-migration-priority-table)

---

## 1. FHE Parameter Setup

Four separate `HE_CKKS` instances are created — one per group of BERT sub-operations.
Each has its own polynomial degree, moduli chain, and scale.

| Instance | BERT Operations Covered | `poly_modulus_degree` | Coefficient Moduli Bits | `he_scale` (CKKS delta) |
|----------|------------------------|-----------------------|-------------------------|--------------------------|
| `he1`    | LayerNorm + Attention (QK^T) | 32768 | `{60, 34, 60, 60, 60, 60, 60}` | 2^44 |
| `he2`    | Softmax + V projection + LayerNorm | 32768 | `{60, 60, 60, 60, 60, 60, 60}` | 2^43 |
| `he3`    | Linear3 + GeLU | 32768 | `{60, 32, 60, 60, 60, 60, 60, 60}` | 2^46 |
| `he4`    | Linear4 + ResidualAdd + LayerNorm | 16384 | `{60, 34, 60, 60, 60}` | 2^38 |

**Defined in:** `SCI/tests/bert_large_bolt/ckks_bert.h`, `he.h:204`, `he.cpp:45,152`

**Security level:** 128-bit (`seal::sec_level_type::tc128`) — `he.h:210`

**Slots per ciphertext:** `poly_modulus_degree / 2`  
e.g., degree 32768 → 16384 slots (complex packing)

**FFT scale:** `fft_scale = 20` (fixed-point scale for the custom NTT/FFT in the FHE↔MPC conversion)

**Key generation:** `he.cpp:57-64, 166-173`
```cpp
KeyGenerator keygen(*context);
SecretKey sec_key = keygen.secret_key();
PublicKey pub_key;
keygen.create_public_key(pub_key);
GaloisKeys gal_keys;
keygen.create_galois_keys(gal_keys);   // all rotations
RelinKeys relin_keys;
keygen.create_relin_keys(relin_keys);  // post-multiplication
```

---

## 2. SEAL Data Structures

All instances owned by the `HE_CKKS` class (`he.h`).

| SEAL Type | Variable Name | Declared | Purpose |
|-----------|--------------|----------|---------|
| `SEALContext*` | `context` | `he.h:210` | Holds encryption params + derived data |
| `EncryptionParameters` | `parms` | `he.h:204` | Scheme, degree, moduli |
| `KeyGenerator` | *(local)* | `he.cpp:57, 166` | Generates all keys |
| `SecretKey` | `sec_key` | `he.h:233` | Decryption key (client) |
| `PublicKey` | `pub_key` | `he.h:234` | Encryption key (server) |
| `GaloisKeys` | `gal_keys` | `he.h:237` | Rotation keys |
| `RelinKeys` | `relin_keys` | `he.h:238` | Relinearization keys |
| `CKKSEncoder*` | `encoder` | `he.h:213` | CKKS encode/decode |
| `Encryptor*` | `encryptor` | `he.h:239` | Plaintext → Ciphertext |
| `Decryptor*` | `decryptor` | `he.h:240` | Ciphertext → Plaintext |
| `Evaluator*` | `evaluator` | `he.h:241` | All homomorphic operations |
| `Ciphertext` | *(various)* | All `.cpp` files | Encrypted polynomial pair |
| `Plaintext` | *(various)* | All `.cpp` files | Unencrypted polynomial |

**Ciphertext data flow:**
```
Client (BOB) → encrypt()
    → send_encrypted_vector(io, cts)        [network]
        → Server (ALICE) recv_encrypted_vector(context, io, cts)
            → homomorphic ops (multiply, add, rotate, relinearize, rescale)
                → send result back to client
                    → Client decrypt()
```

**Key serialization** (for sending over network):
- `pub_key.save()` / `pub_key.load()` — `he.cpp:177, 212`
- `gal_keys.save()` / `gal_keys.load()` — `he.cpp:178-179, 215`
- `relin_keys.save()` / `relin_keys.load()` — `he.cpp:180-181, 217`

---

## 3. Evaluator Operations (FHE Core)

All calls go through `evaluator` (pointer to `seal::Evaluator`).  
Files: `ckks_bert.cpp`, `linear_ckks.cpp`

### Arithmetic

| SEAL Call | Files / Lines | BERT Context | Frequency |
|-----------|--------------|--------------|-----------|
| `evaluator->multiply_plain_inplace(ct, pt)` | `ckks_bert.cpp:296,573,620,852,900,1163,1175,1214,1216` | Weight/bias mul in LayerNorm, linear projections | 9+ |
| `evaluator->multiply_inplace(ct1, ct2)` | `ckks_bert.cpp:298,901` | Ciphertext×ciphertext (variance, attention) | 2+ |
| `evaluator->multiply(ct1, ct2, result)` | `linear_ckks.cpp:1005,1010` | QK^T cross-product | 2+ |
| `evaluator->add_inplace(ct1, ct2)` | `ckks_bert.cpp:270,278,540,564,611,748,751,768,911` | Residual add, accumulation | 9+ |
| `evaluator->add(ct1, ct2, result)` | `ckks_bert.cpp:716-718,878,881,1046` | Accumulation with explicit output | 6+ |
| `evaluator->add_plain_inplace(ct, pt)` | `ckks_bert.cpp:293,302,492,779,781,1094` | Add bias (plaintext) | 6+ |
| `evaluator->sub_inplace(ct1, ct2)` | `ckks_bert.cpp:585,1176` | Subtract ciphertexts | 2+ |
| `evaluator->sub(ct1, ct2, result)` | `ckks_bert.cpp:266,465,867` | Subtract with output | 3+ |
| `evaluator->square_inplace(ct)` | `ckks_bert.cpp:598,1193` | Variance computation (x^2) | 2+ |

### Scale Management (CKKS-specific)

| SEAL Call | Files / Lines | Purpose | Frequency |
|-----------|--------------|---------|-----------|
| `evaluator->relinearize_inplace(ct, rk)` | `ckks_bert.cpp:299,542,599,905,926,1022` | Reduce ct size after multiply | 6+ |
| `evaluator->rescale_to_next_inplace(ct)` | `ckks_bert.cpp:303,541,586,601,604,624` | Drop one level, rescale | 6+ |
| `evaluator->rescale_to_next(ct, result)` | `ckks_bert.cpp:519,938` | Rescale into new ct | 2+ |
| `evaluator->mod_switch_to_next_inplace(ct)` | `ckks_bert.cpp:601,602,1195,1196` | Level drop without rescale | 4+ |

### Rotation & Conjugation

| SEAL Call | Files / Lines | BERT Context | Frequency |
|-----------|--------------|--------------|-----------|
| `evaluator->rotate_vector(ct, step, gk, result)` | `ckks_bert.cpp:557,610,675,767,850,910,1033,1069,1070,1146` | Slot rotation for matrix mul, attention | 10+ |
| `evaluator->rotate_vector_inplace(ct, step, gk)` | `linear_ckks.cpp:767,769` | In-place slot rotation | 2+ |
| `evaluator->complex_conjugate(ct, gk, result)` | `ckks_bert.cpp:263,274,462,478,864,875,1079` | x+yi → x-yi (real-part extraction) | 7+ |

> **Note:** `rotate_columns()` / `rotate_rows()` appear only for BFV — not used in CKKS path.

---

## 4. Encoder / Encryptor / Decryptor

### Encoding

| SEAL Call | Files / Lines | Context | Frequency |
|-----------|--------------|---------|-----------|
| `encoder->encode(values, scale, pt)` | `ckks_bert.cpp:249-250,279-280,310,344,378-379,415,421,508-509,524-525,532-533,652,658,828,833,852,853,1090` | Encode weights, biases, masks as CKKS plaintexts | 20+ |
| `encoder->decode(pt, values)` | `linear_ckks.cpp:1108` | Decode plaintext to doubles (debug / output) | 1 |

### Encryption / Decryption

| SEAL Call | Files / Lines | Context | Frequency |
|-----------|--------------|---------|-----------|
| `encryptor->encrypt(pt, ct)` | `ckks_bert.cpp:218,219,414,422,1091` | Client-side: encrypt MPC → FHE shares | 5+ |
| `decryptor->decrypt(ct, pt)` | `ckks_bert.cpp:232,383,435,443,447,1107` | Client-side: decrypt FHE → MPC shares | 6+ |
| `decryptor->invariant_noise_budget(ct)` | `utils-HE.h` | Debugging only — check remaining noise budget | rare |

---

## 5. SEAL Low-Level Internals

These are the hardest parts to migrate — they reach into SEAL's private `util::` namespace
and bypass the public API. They appear inside the custom FHE↔MPC conversion functions.

**File:** `he.cpp`

### NTT / Inverse NTT

| SEAL Internal | Line | Purpose |
|---------------|------|---------|
| `seal::util::ntt_negacyclic_harvey(data, tables)` | `he.cpp:455` | Forward NTT (polynomial → evaluation form) |
| `seal::util::inverse_ntt_negacyclic_harvey(data, tables)` | `he.cpp:482` | Inverse NTT (evaluation form → polynomial) |
| `context_data.small_ntt_tables()` | `he.cpp:318` | Fetch NTT tables per modulus |

### RNS (Residue Number System) Operations

| SEAL Internal | Line | Purpose |
|---------------|------|---------|
| `context_data.rns_tool()->base_q()->decompose(data, pool)` | `he.cpp:424` | Split into RNS components for NTT |
| `context_data.rns_tool()->base_q()->compose_array(data, n, pool)` | `he.cpp:486` | Reconstruct from RNS after INTT |

### Modular Arithmetic

| SEAL Internal | Line | Purpose |
|---------------|------|---------|
| `util::barrett_reduce_64(a, mod)` | `he.cpp:364,371` | Fast mod reduction (64-bit) |
| `util::barrett_reduce_128(a_hi, a_lo, mod)` | `he.cpp:391,398` | Fast mod reduction (128-bit) |
| `util::negate_uint_mod(a, mod)` | `he.cpp:363,391,431`; `ckks_bert_basic.cpp:95` | Negate modulo Q |
| `util::reverse_bits(val, bit_count)` | `he.h:129` | Bit reversal for FFT |
| `util::ComplexRoots` | `he.h:143` | Complex roots of unity for FFT |

### FFT / IFFT (used inside ckks_encode / ckks_decode)

| Function | Line | Purpose |
|----------|------|---------|
| `fft_handler_.transform_to_rev(data, n, roots)` | `he.cpp:554` | Forward FFT (encode side) |
| `fft_handler_.transform_from_rev(data, n, roots)` | `he.cpp:586` | Inverse FFT (decode side) |
| `he->ifft()` | `he.cpp:299` | Called inside `ckks_encode()` |
| `he->fft()` | `he.cpp:271` | Called inside `ckks_decode()` |

> **Migration note:** The low-level NTT/RNS functions are the most SEAL-specific.
> OpenFHE exposes equivalent functionality through its own `DCRTPoly` and `NativeVector`
> internals. The public `EvalAdd`, `EvalMult`, etc. APIs are straightforward; the
> low-level conversion code (`ckks_ntt`, `ckks_intt`, `ckks_encode`, `ckks_decode`) will
> need the most careful rewriting.

---

## 6. FHE ↔ MPC Conversion Boundaries

These are the critical boundary functions. Every non-linear op crosses here.  
**File:** `ckks_bert_basic.cpp`

### MPC → FHE: `mpc_to_ckks()` (lines 275–326)

Converts MPC ring shares into CKKS plaintexts ready for homomorphic operation.

```
Input:  MPC shares (ell-bit, scale s_in=30)
Output: vector<Plaintext> (CKKS, scale s_out=41–46)

Steps:
  1. he->ckks_encode()    [line 286]  — scalars → complex polynomial (via IFFT)
  2. nonlinear.ring_to_field()        — 2^bitwidth ring → modulus-Q field representation
  3. he->ckks_ntt()       [line 321]  — polynomial → NTT evaluation form (for SEAL storage)
```

### FHE → MPC: `ckks_to_mpc()` (lines 197–264)

Converts decrypted CKKS plaintexts back into MPC ring shares.

```
Input:  vector<Plaintext> (decrypted CKKS)
Output: MPC shares (ell-bit, scale s_out)

Steps:
  1. he->ckks_intt()      [line 208]  — NTT form → polynomial (via INTT)
  2. nonlinear.field_to_ring()        — modulus-Q field → 2^bit_out ring
  3. he->ckks_decode()    [line 252]  — complex polynomial → scalar values (via FFT)
```

**Scale bridging:** MPC uses 2^s_in (typically s_in=30); CKKS uses 2^he_scale (41–46).
The `ring_to_field` / `field_to_ring` pair handles this conversion numerically.

---

## 7. MPC Protocol Functions

MPC operations handle all non-linear layers (GeLU, Softmax, LayerNorm).

### Framework Objects

```cpp
IOPack*  iopackArr[MAX_THREADS];   // Party-to-party I/O
OTPack*  otpackArr[MAX_THREADS];   // Oblivious Transfer packs
FPMath*  fpmath[MAX_THREADS];      // Fixed-point math (thread-local)
```

### MPC Share Type

```cpp
struct FixArray {
    uint64_t* data;   // Share values
    int ell;          // Bit width
    int s;            // Fixed-point scale
    int size;         // Element count
    bool signed_;
    int party;        // ALICE or BOB
};
```

### Key MPC Calls

| Function | File / Line | BERT Operation | Protocol |
|----------|------------|----------------|---------|
| `fpmath->fix->input(party, data, size, signed_, ell, s)` | `ckks_bert.cpp:696-697,1272-1273` | Convert raw values to MPC shares | Secret sharing |
| `nonlinear.field_to_ring(shares, Q, bit_out, s_out)` | `ckks_bert_basic.cpp:227-236` | FHE→MPC field conversion | Ring arithmetic |
| `nonlinear.ring_to_field(shares, Q, bitwidth, s_in)` | `ckks_bert_basic.cpp:308` | MPC→FHE field conversion | Ring arithmetic |
| GeLU (polynomial MPC eval) | `nonlinear.h` | GeLU activation | 5th-deg poly over FixArray |
| Softmax (secure exp + reciprocal) | `nonlinear.h` | Attention softmax | OT-based exp + Newton |
| LayerNorm (secure sqrt) | `nonlinear.h` | LayerNorm variance normalization | Secure sqrt via MPC |
| Tanh (polynomial MPC eval) | `nonlinear.h` | Classifier pooling | 5th-deg poly |

> MPC non-linear functions are **not replaced** in the SEAL→OpenFHE migration. Only the FHE
> side changes. The MPC protocol code (SCI library, OT, FPMath) stays as-is.

---

## 8. BERT Operation → FHE/MPC Mapping

One full BERT-Base encoder layer = 5 FHE blocks + MPC calls between them.

```
BERT Encoder Layer i
│
├─ [MPC] LayerNorm Part 1
│    secure mean, variance, sqrt
│
├─ [FHE / he1] LayerNorm Part 2 + Attention
│    ├─ linear_1()         : Q, K, V projections
│    │    bert_cipher_plain_bsgs()
│    │    → multiply_plain + rotate_vector + add (per head)
│    └─ QK^T
│         bert_cipher_cipher_cross_packing()
│         → multiply + rotate_vector + multiply_plain (masking)
│
├─ [MPC] Softmax
│    secure exp + reciprocal
│
├─ [FHE / he2] Softmax×V + Output Projection + LayerNorm Part 1
│    ├─ linear_2()         : output projection
│    │    bert_cipher_plain_bsgs_2()
│    │    → rotate_vector + multiply_plain + add + flood_ciphertext
│    └─ Residual add + mean/variance for LayerNorm
│         add_inplace + rotate_vector + square_inplace + relinearize + rescale
│
├─ [MPC] LayerNorm normalization (sqrt, scale, bias)
│
├─ [FHE / he3] Linear3 + GeLU Part 1
│    linear projection → GeLU poly eval
│    bert_cipher_plain_bsgs + eval_gelu_poly
│    → multiply + rescale (multiple rounds for poly)
│
├─ [MPC] GeLU Part 2 (non-polynomial tail, if any)
│
└─ [FHE / he4] Linear4 + ResidualAdd + LayerNorm
     bert_cipher_plain_bsgs_2
     → rotate_vector + multiply_plain + add + rescale
```

### Linear Layer Kernel: `bert_cipher_plain_bsgs`

Baby-Step Giant-Step diagonal matrix encoding for encrypted matrix multiplication.
This is where the bulk of the rotation + multiply calls originate.

```
For each diagonal d:
  rotate_vector(ct, d, gal_keys, tmp)
  multiply_plain_inplace(tmp, weight_diag[d])
  add_inplace(result, tmp)
After all diagonals:
  relinearize_inplace(result, relin_keys)
  rescale_to_next_inplace(result)
  flood_ciphertext(result)   // add noise for IND-CPA
```

---

## 9. Migration Priority Table

For SEAL → OpenFHE, tackle in this order:

| Priority | Component | SEAL Artifact | Notes |
|----------|-----------|--------------|-------|
| 1 | Context + Params | `SEALContext`, `EncryptionParameters` | OpenFHE uses `CryptoContext<DCRTPoly>` |
| 2 | Key generation | `KeyGenerator`, `GaloisKeys`, `RelinKeys` | API differs; rotation key gen differs |
| 3 | High-level evaluator ops | All `evaluator->*` calls | Near 1:1 mapping in OpenFHE CKKS |
| 4 | Encoder/Encryptor/Decryptor | `CKKSEncoder`, `Encryptor`, `Decryptor` | OpenFHE merges encode+encrypt into `Encrypt` |
| 5 | Key serialization | `pub_key.save()` / `.load()` | OpenFHE uses `Serial::Serialize` |
| 6 | Low-level NTT/RNS | `util::ntt_negacyclic_harvey`, `rns_tool` | Most complex — needs OpenFHE DCRTPoly internals |
| 7 | FHE↔MPC conversion | `mpc_to_ckks`, `ckks_to_mpc`, `ckks_ntt`, `ckks_intt` | Depends on #6; test heavily |

> **Key OpenFHE difference:** In SEAL, encode and encrypt are separate steps.
> In OpenFHE CKKS, `MakePackedPlaintext` + `Encrypt` replaces `encoder->encode` + `encryptor->encrypt`.
> The `Evaluator` pattern is replaced by methods on `CryptoContext`.
