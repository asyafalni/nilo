# Every release against the one before it

What `bench/release.py` reads for each release, every module side by side with the releases before it, and what the reading found ([ADR 242](../../docs/adr/242-a-release-is-measured-against-the-one-before-it.md)). The **Release numbers** workflow attaches the same table to each release page; it is copied here under its version so the series lives in the repository.

**How to read a table.** A figure is comparable with the figures in its own table, measured in the same run on the same machine, and not with a figure from another table: glibc picks its string functions by CPU, and a different runner is a different CPU. The change in brackets is the record. Instructions are counted by cachegrind and RSS is page-granular, so "inside the spread" is rare and a change of a few instructions is a real one; whether it matters is ADR 017's question, not this file's.

## Backfill: v0.2.0 to `main`

Run on 2026-10-01 at `d8ff14b` (`main` after v0.6.0), `python3 bench/release.py v0.2.0 v0.3.0 v0.4.0 v0.5.0 v0.6.0 HEAD`, inside an Ubuntu 24.04 container with valgrind on the host's Ryzen 7 9700X, seccomp off so io_uring was there as on a CI virtual machine. v0.1.0 is not here: it has no `bench/main.zig`. The two rounds agreed to 0.004 instructions a request on `http` and exactly everywhere else, and every idle-connection reading was the same to the byte. The whole run took 232 seconds with the six trees already built; a cold run of three refs took 106.

This table is the second run. The first had `s3` at +960 on `main`, because its `main` rows happened to sign in seconds :00 to :09 and its v0.6.0 rows did not (`docs/history.md`, "An instruction count is exact and can still follow the clock"); every other figure of the two runs is identical. `s3` is now measured for every ref inside one minute, and its column sits 192 higher than the first run's at every ref, which is the clock's digits that minute and not the code.

### Instructions an operation

| module | v0.2.0 `1e8cc01` | v0.3.0 `b302549` | v0.4.0 `eb545fa` | v0.5.0 `c7147f9` | v0.6.0 `221e1b3` | HEAD `d8ff14b` |
|---|---|---|---|---|---|---|
| http | 11,454 | 12,777 (+1,323, +11.55%) | 12,870 (+93, +0.73%) | 12,872 (+2, +0.02%) | 13,068–13,069 (+196, +1.52%) | 13,633 (+565, +4.32%) |
| core | 3,978 | 3,978 (unchanged) | 3,978 (unchanged) | 3,978 (unchanged) | 3,978 (unchanged) | 3,978 (unchanged) |
| id | 859 | 859 (unchanged) | 859 (unchanged) | 859 (unchanged) | 859 (unchanged) | 859 (unchanged) |
| config | 406 | 406 (unchanged) | 406 (unchanged) | 406 (unchanged) | 406 (unchanged) | 406 (unchanged) |
| pw | 285,101,776 | 285,101,776 (unchanged) | 285,101,776 (unchanged) | 285,101,776 (unchanged) | 285,101,776 (unchanged) | 285,101,776 (unchanged) |
| cache | n/a | 580 | 740 (+161, +27.68%) | 740 (unchanged) | 740 (unchanged) | 747 (+7, +0.89%) |
| jwt | n/a | 3,722,513 | 3,722,513 (unchanged) | 3,722,021 (-492, -0.01%) | 3,722,093 (+72, +0.00%) | 3,722,093 (unchanged) |
| fetch | 9,152 | 9,151 (-1, -0.01%) | 9,160 (+9, +0.10%) | 9,735 (+575, +6.28%) | 9,759 (+24, +0.25%) | 9,767 (+8, +0.08%) |
| job | n/a | n/a | 5,055 | 5,047 (-8, -0.16%) | 5,132 (+85, +1.68%) | 5,255 (+123, +2.40%) |
| sql | 7,061 | 7,831 (+770, +10.90%) | 7,831 (unchanged) | 7,831 (unchanged) | 7,835 (+4, +0.05%) | 7,522 (-313, -3.99%) |
| s3 | 54,012 | 54,006 (-6, -0.01%) | 54,034 (+28, +0.05%) | 54,703 (+669, +1.24%) | 54,738 (+35, +0.06%) | 55,508 (+770, +1.41%) |

### Allocations an operation

| module | v0.2.0 `1e8cc01` | v0.3.0 `b302549` | v0.4.0 `eb545fa` | v0.5.0 `c7147f9` | v0.6.0 `221e1b3` | HEAD `d8ff14b` |
|---|---|---|---|---|---|---|
| core | 2 | 2 (unchanged) | 2 (unchanged) | 2 (unchanged) | 2 (unchanged) | 2 (unchanged) |
| id | 0 | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) |
| config | 0 | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) |
| pw | 1 | 1 (unchanged) | 1 (unchanged) | 1 (unchanged) | 1 (unchanged) | 1 (unchanged) |
| cache | n/a | 0 | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) |
| jwt | n/a | 2 | 2 (unchanged) | 4 (+2, +100.00%) | 4 (unchanged) | 4 (unchanged) |
| fetch | 1 | 1 (unchanged) | 1 (unchanged) | 2 (+1, +100.00%) | 2 (unchanged) | 2 (unchanged) |
| job | n/a | n/a | 1 | 1 (unchanged) | 1 (unchanged) | 1 (unchanged) |
| sql | 3 | 3 (unchanged) | 3 (unchanged) | 3 (unchanged) | 3 (unchanged) | 2 (-1, -33.33%) |
| s3 | 1 | 1 (unchanged) | 1 (unchanged) | 1 (unchanged) | 1 (unchanged) | 1 (unchanged) |

### Bytes allocated an operation

| module | v0.2.0 `1e8cc01` | v0.3.0 `b302549` | v0.4.0 `eb545fa` | v0.5.0 `c7147f9` | v0.6.0 `221e1b3` | HEAD `d8ff14b` |
|---|---|---|---|---|---|---|
| core | 55 | 55 (unchanged) | 55 (unchanged) | 55 (unchanged) | 55 (unchanged) | 55 (unchanged) |
| id | 0 | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) |
| config | 0 | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) |
| pw | 19,922,944 | 19,922,944 (unchanged) | 19,922,944 (unchanged) | 19,922,944 (unchanged) | 19,922,944 (unchanged) | 19,922,944 (unchanged) |
| cache | n/a | 0 | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) | 0 (unchanged) |
| jwt | n/a | 1,619 | 1,619 (unchanged) | 1,898 (+279, +17.23%) | 1,898 (unchanged) | 1,898 (unchanged) |
| fetch | 429 | 429 (unchanged) | 429 (unchanged) | 495 (+66, +15.38%) | 495 (unchanged) | 495 (unchanged) |
| job | n/a | n/a | 260 | 260 (unchanged) | 260 (unchanged) | 8,648 (+8,388, +3226.15%) |
| sql | 74 | 74 (unchanged) | 74 (unchanged) | 74 (unchanged) | 74 (unchanged) | 74 (unchanged) |
| s3 | 1,082 | 1,082 (unchanged) | 1,082 (unchanged) | 1,082 (unchanged) | 1,082 (unchanged) | 1,082 (unchanged) |

### Stripped binary bytes

| module | v0.2.0 `1e8cc01` | v0.3.0 `b302549` | v0.4.0 `eb545fa` | v0.5.0 `c7147f9` | v0.6.0 `221e1b3` | HEAD `d8ff14b` |
|---|---|---|---|---|---|---|
| http | 895,168 | 924,672 (+29,504, +3.30%) | 930,096 (+5,424, +0.59%) | 945,144 (+15,048, +1.62%) | 974,392 (+29,248, +3.09%) | 1,013,208 (+38,816, +3.98%) |
| core | 227,784 | 227,784 (unchanged) | 227,784 (unchanged) | 227,784 (unchanged) | 227,784 (unchanged) | 227,784 (unchanged) |
| id | 224,776 | 224,776 (unchanged) | 224,776 (unchanged) | 224,776 (unchanged) | 224,776 (unchanged) | 224,776 (unchanged) |
| config | 226,632 | 226,632 (unchanged) | 226,632 (unchanged) | 226,632 (unchanged) | 226,632 (unchanged) | 226,632 (unchanged) |
| pw | 262,168 | 262,168 (unchanged) | 262,168 (unchanged) | 262,168 (unchanged) | 262,168 (unchanged) | 262,168 (unchanged) |
| cache | n/a | 235,480 | 239,224 (+3,744, +1.59%) | 239,224 (unchanged) | 239,224 (unchanged) | 242,776 (+3,552, +1.48%) |
| jwt | n/a | 362,312 | 362,312 (unchanged) | 409,912 (+47,600, +13.14%) | 409,912 (unchanged) | 409,912 (unchanged) |
| fetch | 881,048 | 881,112 (+64, +0.01%) | 881,704 (+592, +0.07%) | 899,624 (+17,920, +2.03%) | 899,784 (+160, +0.02%) | 900,480 (+696, +0.08%) |
| job | n/a | n/a | 300,120 | 300,184 (+64, +0.02%) | 301,480 (+1,296, +0.43%) | 325,344 (+23,864, +7.92%) |
| sql | 1,433,416 | 1,459,384 (+25,968, +1.81%) | 1,459,176 (-208, -0.01%) | 1,461,608 (+2,432, +0.17%) | 1,460,696 (-912, -0.06%) | 1,466,408 (+5,712, +0.39%) |
| s3 | 921,528 | 921,512 (-16, -0.00%) | 923,240 (+1,728, +0.19%) | 936,696 (+13,456, +1.46%) | 936,904 (+208, +0.02%) | 950,144 (+13,240, +1.41%) |

### Bytes an idle connection

| module | v0.2.0 `1e8cc01` | v0.3.0 `b302549` | v0.4.0 `eb545fa` | v0.5.0 `c7147f9` | v0.6.0 `221e1b3` | HEAD `d8ff14b` |
|---|---|---|---|---|---|---|
| http | 4,674 | 5,186 (+512, +10.96%) | 5,186 (unchanged) | 5,186 (unchanged) | 5,186 (unchanged) | 5,186 (unchanged) |

### What each operation is

| module | one operation | counts |
|---|---|---|
| http | a `GET /users/7` answered with 1 KB of JSON | 1,000 and 5,000 |
| core | a path param and a query value percent-decoded, a number read from a `Str` | 1,000 and 5,000 |
| id | a v7 key made, printed and parsed back | 1,000 and 5,000 |
| config | a five-field settings struct read from pairs | 1,000 and 5,000 |
| pw | a password checked against its Argon2id hash at the default Cost | 2 and 6 |
| cache | one `put` and one `get` of a flat value | 1,000 and 5,000 |
| jwt | an RS256 token verified, its claims read | 20 and 100 |
| fetch | a GET on a pooled keep-alive connection to an upstream in the process | 1,000 and 5,000 |
| job | a job pushed onto `job.Memory`, claimed, run and marked done | 2,000 and 10,000 |
| sql | a row found by key on SQLite, `.in_fiber` | 1,000 and 21,000 |
| s3 | a GetObject signed with SigV4 from a stub in the process | 1,000 and 5,000 |

### Not measured

- `cache` at v0.2.0: error: this ref exports no nilo_cache
- `jwt` at v0.2.0: error: this ref exports no nilo_jwt
- `job` at v0.2.0: error: this ref exports no nilo_job
- `job` at v0.3.0: error: this ref exports no nilo_job

### Built byte-identical to an earlier ref

- v0.3.0: `core` (as v0.2.0), `id` (as v0.2.0), `config` (as v0.2.0), `pw` (as v0.2.0)
- v0.4.0: `core` (as v0.3.0), `id` (as v0.3.0), `config` (as v0.3.0), `pw` (as v0.3.0), `jwt` (as v0.3.0)
- v0.5.0: `core` (as v0.4.0), `id` (as v0.4.0), `config` (as v0.4.0), `pw` (as v0.4.0), `cache` (as v0.4.0)
- v0.6.0: `core` (as v0.5.0), `id` (as v0.5.0), `config` (as v0.5.0), `pw` (as v0.5.0), `cache` (as v0.5.0)
- HEAD: `core` (as v0.6.0), `id` (as v0.6.0), `config` (as v0.6.0), `pw` (as v0.6.0), `jwt` (as v0.6.0)

Measured on AMD Ryzen 7 9700X 8-Core Processor (16 CPUs), Linux 7.2.5-3-omarchy, Zig 0.16.0, valgrind-3.22.0, 2 interleaved rounds, a range where they differed. A change in brackets is against the column to its left, and reads "inside the spread" when the two ranges overlap. How to read it: ADR 242.

### What it found

- **An idle connection grew 512 bytes between v0.2.0 and v0.3.0**, 4,674 to 5,186, and has stayed there. ADR 017, the principles page and `bench/result/http.md` still quote 4,669 (the ADR 062 run, on `bench/ws_server.zig`'s HTTP control), and nothing since had re-measured it on the benchmark server. Not run down here; it is on the roadmap under Measurements outstanding.
- **`http` costs 19% more instructions a request than at v0.2.0**: +11.6% at v0.3.0, then +0.7%, +0.0%, +1.5%, and +4.3% on `main` since v0.6.0, over the audit fixes. Instructions are not time, so this is not ADR 017's 10% on requests a second; it is where to point a box next.
- **`nilo_job`'s Run arena grows by 8,648 bytes a job on `main`, against 260 at v0.6.0.** `Memory.claim` now takes a buffer of `max_kind + max_payload` from the arena before it scans, which v0.6.0 did not. `runOne` takes only a `*core.Run`, so `job.zig` counts the Run's arena chunks and not the module's requests: the direction is exact and the size is the arena's. Unreleased, so it is the kind of change this exists to put in front of a release.
- **`nilo_sql` on `main` is one allocation and 313 instructions a find cheaper than v0.6.0.**
- **`nilo_s3` is +770 instructions a GetObject on `main`, +1.4%**, beside +1.24% at v0.5.0.
- **The steps that were already known show up where they should:** `nilo_fetch` keeping a response's header block (ADR 187) is the second allocation and +6.3% at v0.5.0, and `nilo_jwt` at v0.5.0 is ES256 arriving, +47.6 KB of binary and two allocations a verify.
- **`core`, `id`, `config` and `pw` have built byte-identical since v0.2.0**, so their rows are a check that the harness itself is steady.

**Can it be pushed further?** The 512 bytes and the 19% are both unexplained; each is a bisect between two tags with this script and `--only`, at about ten minutes a step.
