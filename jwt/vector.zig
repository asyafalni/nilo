//! RSA, EC and OKP keys, and a token signed with each — generated or
//! published elsewhere, and pinned here.
//!
//! Signed by somebody else's implementation on purpose. A vector produced by
//! the code under test only proves the code agrees with itself; these were
//! made by a library that has verified against the RFC's own examples, and
//! by the RFC itself, so the DigestInfo prefix, the PKCS#1 padding and the
//! `r || s` layout are being checked rather than restated.
//!
//! The RS256 payload is `{"iss":"https://accounts.example","aud":"client-1",
//! "sub":"u-7","email":"a@example.com","exp":2000000000,"nbf":1000000000}`.
//! The ES256 vector is RFC 7515 Appendix A.3 verbatim — header
//! `{"alg":"ES256"}`, payload `{"iss":"joe", "exp":1300819380,
//! "http://example.com/is_root":true}` with the RFC's own line breaks, and
//! the public half of the key in A.3.1 — and it was re-checked against an
//! independent P-256 before being pinned.
//!
//! The ES384 and EdDSA vectors are the exception to "published elsewhere":
//! RFC 7515 has no P-384 example and RFC 8037's signed example has a payload
//! that is not JSON, so the token-level ones were made by Python's
//! `cryptography` (OpenSSL), not by this code, and the RFC's Ed25519 example
//! is pinned beside them for the primitive.
//!
//! The mixed key set carries an OKP key after the other two, so that the keys the older tests index by position are still where they were. It was
//! "a type nilo cannot read" until EdDSA landed, as the EC key before it
//! was until ES256 did; the file that holds a key set nilo skips from is now
//! `jwks.zig`'s own tests.
//!
//! **The private keys were thrown away**, or in the RFC's case were never
//! anybody's. Nothing here signs anything, and there is nothing in this
//! file that could.

/// The whole RS256 token: header, payload, signature.
pub const token =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5IiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY2" ++ "91bnRzLmV4YW1wbGUiLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6InUtNyIsImVtYWlsIjoiYUBleGFtcGxlLmNv" ++ "bSIsImV4cCI6MjAwMDAwMDAwMCwibmJmIjoxMDAwMDAwMDAwfQ.AcbsMWT1PLcxeCcSGyy0huOFwmr2veRJJNv" ++ "aLBP2UBsI2Y7_F6-CYF0z6wSahQU5wtFSnR7-ebRGWTpar5J1qFVVg9_XJ4FqhA2R1VmtxijbOXYJkJHQQtuTK" ++ "eRv_AicyxI0oFudf495-reWHHKjBCQJj65Zp-Jd51AqsLpk_jTDZD8NeWRwsXVH-wuofPrb7mKkgsEFIFdAfs2" ++ "ioGPJVI-sdbN7lSKD22UNC2_XWqLCiF50v7rHNJUmVYeozKr2FvTMiF51wh6OGJZ3XUSzDLTXLr80cqDV9__d1" ++ "nQ-VcVWFc8uyNXQChdhihk3GCOjsz3ty6-aIwhEcVvi1lBcvw";

/// The RS256 token's middle segment on its own, for the forged-header tests.
pub const payload =
    "eyJpc3MiOiJodHRwczovL2FjY291bnRzLmV4YW1wbGUiLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6InUtNyIsIm" ++ "VtYWlsIjoiYUBleGFtcGxlLmNvbSIsImV4cCI6MjAwMDAwMDAwMCwibmJmIjoxMDAwMDAwMDAwfQ";

/// The RS256 token's last segment on its own, for a forged header over a
/// real signature.
pub const signature =
    "AcbsMWT1PLcxeCcSGyy0huOFwmr2veRJJNvaLBP2UBsI2Y7_F6-CYF0z6wSahQU5wtFSnR7-ebRGWTpar5J1qFVVg9_" ++ "XJ4FqhA2R1VmtxijbOXYJkJHQQtuTKeRv_AicyxI0oFudf495-reWHHKjBCQJj65Zp-Jd51AqsLpk_jTDZD8NeWR" ++ "wsXVH-wuofPrb7mKkgsEFIFdAfs2ioGPJVI-sdbN7lSKD22UNC2_XWqLCiF50v7rHNJUmVYeozKr2FvTMiF51wh6" ++ "OGJZ3XUSzDLTXLr80cqDV9__d1nQ-VcVWFc8uyNXQChdhihk3GCOjsz3ty6-aIwhEcVvi1lBcvw";

/// The RSA key's `n`, as the JWKS spells it.
pub const rsa_n =
    "tBFYa_IZgELJqUxuRyKGQDsWWYVZO0GHU2VoZzGs8ALOaNcUbtCa50wrUo0cG8BBa069mmo_meOs0IsqOsZCZw4t" ++ "14l8SwHLd2mNthp69GO4djVqC586QAKJ1I8Ngn_uwTDxru9jONNAzu2F1fKiHCZMyD8_QupubOQXlDWLAqk0VHA" ++ "byoEwjdCZhoXCxjuSa8xfdZxOMeiRMrtPbDhIiSJWlRjm3UBMXJXehIuLf1zH9jGtb3PuAPK4IB_JMh0IT-4t28" ++ "bQKxJwUWixCUirVvCI4RQFjjgpIoJn7k4cFWOEFgaejyzqP7mt_mvsqws3rVEuUaViHs6hkbZ_ateTew";

// RFC 7515 Appendix A.3: "Example JWS Using ECDSA P-256 SHA-256".

/// `{"alg":"ES256"}`.
pub const es256_header = "eyJhbGciOiJFUzI1NiJ9";

/// `{"iss":"joe",\r\n "exp":1300819380,\r\n "http://example.com/is_root":true}`.
pub const es256_payload =
    "eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";

/// `r || s`, sixty-four bytes, as RFC 7518 §3.4 lays it out.
pub const es256_signature =
    "DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q";

/// The same `r` and `s` as DER — `SEQUENCE { INTEGER r, INTEGER s }`,
/// seventy-one bytes — which is what every tool outside JOSE writes and what
/// a first attempt at ES256 decodes. Valid arithmetic; the wrong shape.
pub const es256_signature_der =
    "MEUCIA7RIVN5Y2xIPC9_FVgH1AKjsigDOvl8fheBmsMWnqZlAiEAxQoH04w8cOXY8S2vCEpUgKZlkMXyk1Cajz9_ioOjVNU";

/// The whole ES256 token.
pub const es256_token = es256_header ++ "." ++ es256_payload ++ "." ++ es256_signature;

/// The public half of the key in RFC 7515 A.3.1, as the JWKS spells it.
pub const es256_x = "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU";
pub const es256_y = "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0";

/// A key set holding only the RFC's EC key, with no `kid`, which is what
/// the RFC's token — which names none — has to be read against.
pub const es256_jwks =
    "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ es256_x ++ "\",\"y\":\"" ++ es256_y ++ "\"}]}";

// RFC 8037 Appendix A: "Ed25519 Signing".

/// `{"alg":"EdDSA"}`.
pub const rfc8037_header = "eyJhbGciOiJFZERTQSJ9";

/// `Example of Ed25519 signing`, which is not JSON, so it can be verified
/// as a signature and not read as a token.
pub const rfc8037_payload = "RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc";

/// The sixty-four bytes of A.4.
pub const rfc8037_signature =
    "hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg";

/// The public key of A.2 (`d` is not here), as the JWKS spells it.
pub const rfc8037_x = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo";

// ES384 and EdDSA tokens with the registered claims a verifier needs.
// RFC 7515 has no P-384 example and RFC 8037's payload is not JSON, so these
// two were signed by Python's `cryptography` (OpenSSL underneath) with a key
// made for the purpose and thrown away. The payload for both is
// `{"iss":"https://accounts.example","aud":"client-1","sub":"u-7",
// "exp":2000000000}`.

/// `{"alg":"ES384","kid":"es384-key"}`.
pub const es384_header = "eyJhbGciOiJFUzM4NCIsImtpZCI6ImVzMzg0LWtleSJ9";

/// The payload both of the tokens below carry.
pub const claims_payload =
    "eyJpc3MiOiJodHRwczovL2FjY291bnRzLmV4YW1wbGUiLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6InUtNyIsImV4cCI6MjAwMDAwMDAwMH0";
pub const es384_payload = claims_payload;

pub const es384_x = "H2KNEs_ZLD09HspokU_2TSkARpFmuZW1zys0TsuBeSnoTBtWEVREqrMKoJ6KGlrD";
pub const es384_y = "E5u_5HyTw-s2bdv8OGH6dVLUi38zfU4uOTPWa_0RHNe-YvC4fZ3_830NJjQD_AGU";

/// `r || s`, ninety-six bytes.
pub const es384_signature =
    "zNSwWhRiSUMAzfsQKWwPec4lYo1bW3ygYHTGeotfNhVAiYAiZdHW20NHokW_bDOLdG5fSrH098NT5fBIj9SXzN_vyb7NYVNbqgGp8p2REdq5ed4l6i6tdo6hnm0N4sRh";

/// The same `r` and `s` as DER, which is what OpenSSL writes by default.
pub const es384_signature_der =
    "MGUCMQDM1LBaFGJJQwDN-xApbA95ziVijVtbfKBgdMZ6i182FUCJgCJl0dbbQ0eiRb9sM4sCMHRuX0qx9PfDU-XwSI_Ul8zf78m-zWFTW6oBqfKdkRHauXneJeourXaOoZ5tDeLEYQ";

pub const es384_token = es384_header ++ "." ++ es384_payload ++ "." ++ es384_signature;

pub const es384_jwks =
    "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-384\",\"use\":\"sig\",\"kid\":\"es384-key\",\"x\":\"" ++ es384_x ++ "\",\"y\":\"" ++ es384_y ++ "\"}]}";

/// `{"alg":"EdDSA","kid":"ed25519-key"}`.
pub const eddsa_header = "eyJhbGciOiJFZERTQSIsImtpZCI6ImVkMjU1MTkta2V5In0";
pub const eddsa_payload = claims_payload;
pub const eddsa_x = "CLukSdVePIYP2SO2HOboyrJi9r5rKDjRgBV17KTdQwM";
pub const eddsa_signature =
    "bJGfYbGuo6kJ-ZxGy9j4Qyk1WnuVRQqBqIdOCILqj6lstTgNbTSd36Ytc-NU7WyCj2BuXPLzeaaCD5yA9KGYBw";

pub const eddsa_token = eddsa_header ++ "." ++ eddsa_payload ++ "." ++ eddsa_signature;

pub const eddsa_jwks =
    "{\"keys\":[{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"use\":\"sig\",\"kid\":\"ed25519-key\",\"x\":\"" ++ eddsa_x ++ "\"}]}";

/// The issuer's key set, as it would come back from a JWKS endpoint: the RSA
/// key under `test-key`, the RFC's EC key under `es256-key`, and last RFC
/// 8037 A.2's Ed25519 key. No token here is signed by that one (its private
/// half is not kept), so it is read and not used to verify.
pub const jwks =
    "{\"keys\":[" ++
    "{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"kid\":\"test-key\",\"n\":\"" ++ rsa_n ++ "\",\"e\":\"AQAB\"}," ++
    "{\"kty\":\"EC\",\"crv\":\"P-256\",\"use\":\"sig\",\"kid\":\"es256-key\",\"x\":\"" ++ es256_x ++ "\",\"y\":\"" ++ es256_y ++ "\"}," ++
    "{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"kid\":\"an-okp-key\",\"x\":\"" ++ rfc8037_x ++ "\"}" ++
    "]}";
