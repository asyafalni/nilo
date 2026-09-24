# ADR numbers before the renumbering

The ADRs were renumbered once, when amend chains were collapsed into one ADR each. This table exists so that a commit message or a released CHANGELOG entry written before then can still be read. Nothing cites it, and `zig build adr-check` refuses an old number anywhere else.

| Old | New | Note |
|---|---|---|
| 0001 | 017 | merged into 017-the-trade-budget-has-four-axes.md |
| 0002 | 001 | 001-zio-as-the-engine-behind-the-bulkhead.md |
| 0003 | 002 | 002-typed-handlers-are-a-thin-layer-over-ctx.md |
| 0004 | 003 | 003-request-arena-and-the-str-type.md |
| 0005 | 004 | 004-http-errors-via-fail-functions.md |
| 0006 | 005 | 005-services-via-a-runtime-registry.md |
| 0007 | 006 | 006-failure-box-bound-to-the-fiber.md |
| 0008 | 007 | 007-no-recover-middleware.md |
| 0009 | 008 | 008-middleware-is-an-onion-of-ctx-functions.md |
| 0010 | 009 | 009-static-files-are-held-in-memory-or-opened.md |
| 0011 | 010 | 010-shared-services-need-a-lock-from-the-bulkhead.md |
| 0012 | 011 | 011-the-query-string-is-a-struct-of-your-own.md |
| 0013 | 012 | 012-the-most-specific-route-wins-and-duplicates-are-refused.md |
| 0014 | 013 | 013-handlers-must-not-block-the-thread.md |
| 0015 | 014 | 014-what-nilo-borrows-and-from-whom.md |
| 0016 | 015 | 015-resolved-values-are-declared-by-their-type.md |
| 0017 | 016 | 016-the-api-description-comes-from-the-signatures.md |
| 0018 | 017 | 017-the-trade-budget-has-four-axes.md |
| 0019 | 018 | 018-a-response-owns-its-headers.md |
| 0020 | 019 | 019-a-request-that-lasts-is-still-one-request.md |
| 0021 | 020 | 020-a-range-is-a-slice-and-two-headers.md |
| 0022 | 021 | 021-a-websocket-is-a-handler-that-does-not-return.md |
| 0023 | 022 | 022-a-deadline-belongs-to-an-operation-not-to-a-request.md |
| 0024 | 023 | 023-a-failure-mode-belongs-in-the-return-type.md |
| 0025 | 024 | 024-every-failure-answers-as-json.md |
| 0026 | 025 | 025-a-patch-needs-three-answers-and-an-optional-has-two.md |
| 0027 | 026 | 026-the-rule-about-error-messages-is-held-by-a-build-step.md |
| 0028 | 027 | 027-tls-is-terminated-in-front.md |
| 0029 | 028 | 028-a-spawned-fiber-belongs-to-the-server.md |
| 0030 | 029 | 029-a-header-is-checked-once-and-two-of-them-repeat.md |
| 0031 | 030 | 030-a-form-is-the-body-read-by-another-rule.md |
| 0032 | 031 | 031-a-redirect-puts-its-status-in-the-type.md |
| 0033 | 032 | 032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md |
| 0034 | 013 | merged into 013-handlers-must-not-block-the-thread.md |
| 0035 | 033 | 033-a-session-is-sealed-into-the-cookie.md |
| 0036 | 034 | 034-a-binding-hands-its-failures-to-the-handler.md |
| 0037 | 009 | merged into 009-static-files-are-held-in-memory-or-opened.md |
| 0038 | 035 | 035-a-broadcast-rings-a-bell-it-does-not-write.md |
| 0039 | 036 | 036-the-shape-of-a-query-is-settled-while-compiling.md |
| 0040 | 037 | 037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md |
| 0041 | 038 | 038-a-module-sits-where-the-loop-puts-it.md |
| 0042 | 038 | merged into 038-a-module-sits-where-the-loop-puts-it.md |
| 0043 | 039 | 039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md |
| 0044 | 040 | 040-a-condition-holds-a-value-not-a-maybe.md |
| 0045 | 041 | 041-core-knows-what-time-it-is.md |
| 0046 | 042 | 042-entropy-belongs-to-the-loop.md |
| 0047 | 043 | 043-a-deadline-needs-a-connection-you-hold.md |
| 0048 | 044 | 044-a-password-hash-is-gated-because-forgetting-is-silent.md |
| 0049 | 044 | merged into 044-a-password-hash-is-gated-because-forgetting-is-silent.md |
| 0050 | 049 | merged into 049-a-column-type-can-come-from-outside-this-module.md |
| 0051 | 045 | 045-an-array-is-a-slice-and-a-slice-is-one-deep.md |
| 0052 | 046 | 046-a-message-is-copied-once-and-framed-once.md |
| 0053 | 047 | 047-a-batch-is-one-array-per-column.md |
| 0054 | 048 | 048-contention-is-what-a-transaction-is-for.md |
| 0055 | 049 | 049-a-column-type-can-come-from-outside-this-module.md |
| 0056 | 050 | 050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md |
| 0057 | 051 | 051-a-statement-that-is-a-constant-can-be-prepared-once.md |
| 0058 | 052 | 052-a-set-operation-over-one-table-is-a-condition.md |
| 0059 | 053 | 053-a-round-trip-is-not-the-cost-worth-chasing.md |
| 0060 | 054 | 054-a-second-database-is-a-second-type.md |
| 0061 | 055 | 055-the-second-dialect-is-the-test-of-the-seam.md |
| 0062 | 115 | merged into 115-a-boot-dials-the-connection-its-work-needs.md |
| 0063 | 062 | merged into 062-where-a-connection-waits-is-what-it-costs.md |
| 0064 | 039 | merged into 039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md |
| 0065 | 056 | 056-the-way-out-was-open-the-clock-was-not.md |
| 0066 | 057 | 057-percent-is-needed-by-two-layers.md |
| 0067 | 058 | 058-most-of-an-s3-client-is-not-s3.md |
| 0068 | 059 | 059-a-bucket-is-a-type-and-a-key-is-not.md |
| 0069 | 060 | 060-a-signing-key-changes-once-a-day.md |
| 0070 | 061 | 061-a-fitting-borrows-the-loop.md |
| 0071 | 062 | 062-where-a-connection-waits-is-what-it-costs.md |
| 0072 | 063 | 063-an-object-store-is-a-service-that-dials.md |
| 0073 | 064 | 064-a-file-has-no-socket-to-wait-on.md |
| 0074 | 065 | 065-one-writer-is-not-a-setting-it-is-the-database.md |
| 0075 | 066 | 066-a-lazy-dependency-is-a-request.md |
| 0076 | 016 | merged into 016-the-api-description-comes-from-the-signatures.md |
| 0077 | 016 | merged into 016-the-api-description-comes-from-the-signatures.md |
| 0078 | 067 | 067-a-value-is-whatever-the-database-stores.md |
| 0079 | 180 | merged into 180-work-that-needs-the-services-runs-on-their-loop.md |
| 0080 | 008 | merged into 008-middleware-is-an-onion-of-ctx-functions.md |
| 0081 | 034 | merged into 034-a-binding-hands-its-failures-to-the-handler.md |
| 0082 | 034 | merged into 034-a-binding-hands-its-failures-to-the-handler.md |
| 0083 | 068 | 068-the-guide-is-the-source-of-its-own-snippets.md |
| 0084 | 069 | 069-a-library-can-tell-what-mode-the-program-was-built-in.md |
| 0085 | 016 | merged into 016-the-api-description-comes-from-the-signatures.md |
| 0086 | 028 | merged into 028-a-spawned-fiber-belongs-to-the-server.md |
| 0087 | 029 | merged into 029-a-header-is-checked-once-and-two-of-them-repeat.md |
| 0088 | 033 | merged into 033-a-session-is-sealed-into-the-cookie.md |
| 0089 | 029 | merged into 029-a-header-is-checked-once-and-two-of-them-repeat.md |
| 0090 | 070 | 070-a-request-nobody-else-would-answer-is-refused.md |
| 0091 | 058 | merged into 058-most-of-an-s3-client-is-not-s3.md |
| 0092 | 071 | 071-a-checkbox-is-a-bool-in-a-form-and-nowhere-else.md |
| 0093 | 072 | 072-two-renamed-names-that-collide-are-refused.md |
| 0094 | 073 | 073-a-header-is-answered-as-asked-or-refused.md |
| 0095 | 074 | 074-a-type-says-its-own-name.md |
| 0096 | 075 | 075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md |
| 0097 | 076 | 076-a-frame-that-lies-about-its-length-is-not-sent.md |
| 0098 | 077 | 077-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md |
| 0099 | 078 | 078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md |
| 0100 | 079 | 079-the-route-table-is-the-registry.md |
| 0101 | 070 | merged into 070-a-request-nobody-else-would-answer-is-refused.md |
| 0102 | 080 | 080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md |
| 0103 | 081 | 081-one-file-decides-what-counts-as-text.md |
| 0104 | 082 | 082-a-cleanup-path-is-not-cancellable.md |
| 0105 | 083 | 083-a-body-is-taken-as-it-arrives.md |
| 0106 | 084 | 084-a-number-in-a-request-is-not-a-zig-literal.md |
| 0107 | 085 | 085-every-header-without-handing-out-the-head.md |
| 0108 | 086 | 086-the-test-client-can-do-what-a-client-does.md |
| 0109 | 087 | 087-a-fallback-answers-a-navigation-not-a-missing-asset.md |
| 0110 | 088 | 088-an-origin-is-a-fact-about-the-deployment.md |
| 0111 | 089 | 089-a-body-under-an-encoding-other-than-gzip-is-refused.md |
| 0112 | 090 | 090-a-request-can-be-read-past-the-parts-a-handler-names.md |
| 0113 | 091 | 091-a-websocket-route-can-be-driven-from-a-test.md |
| 0114 | 092 | 092-an-allowance-is-a-table-sized-while-compiling.md |
| 0115 | 050 | merged into 050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md |
| 0116 | 065 | merged into 065-one-writer-is-not-a-setting-it-is-the-database.md |
| 0117 | 093 | 093-a-guard-against-double-release-is-not-a-debug-trap.md |
| 0118 | 094 | 094-a-null-is-refused-by-both-wires-or-by-neither.md |
| 0119 | 067 | merged into 067-a-value-is-whatever-the-database-stores.md |
| 0120 | 095 | 095-a-target-is-read-in-the-form-it-arrived-in.md |
| 0121 | 096 | 096-a-byte-that-is-not-text-is-not-a-string.md |
| 0122 | 074 | merged into 074-a-type-says-its-own-name.md |
| 0123 | 097 | 097-a-file-is-written-by-the-engine.md |
| 0124 | 022 | merged into 022-a-deadline-belongs-to-an-operation-not-to-a-request.md |
| 0125 | 098 | 098-a-file-is-described-by-the-descriptor-being-sent.md |
| 0126 | 099 | 099-a-route-can-say-what-covers-it.md |
| 0127 | 100 | 100-a-route-pattern-is-the-name-of-its-url.md |
| 0128 | 101 | 101-a-stream-that-knows-its-length-says-so.md |
| 0129 | 102 | 102-a-proxy-is-trusted-by-which-one-it-is.md |
| 0130 | 103 | 103-a-path-is-an-address-to-listen-on.md |
| 0131 | 104 | 104-a-key-the-application-knows-is-a-word-of-its-own.md |
| 0132 | 013 | merged into 013-handlers-must-not-block-the-thread.md |
| 0133 | 105 | 105-a-route-can-say-how-long-it-has.md |
| 0134 | 106 | 106-a-select-list-shorter-than-the-row-is-refused.md |
| 0135 | 107 | 107-a-wait-for-a-connection-has-a-bound.md |
| 0136 | 067 | merged into 067-a-value-is-whatever-the-database-stores.md |
| 0137 | 108 | 108-a-statement-can-be-watched.md |
| 0138 | 109 | 109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md |
| 0139 | 110 | 110-an-in-process-cache-and-a-redis-client-are-two-modules.md |
| 0140 | 111 | 111-nilo-verifies-a-token-and-does-not-fetch-one.md |
| 0141 | 112 | 112-a-browser-uploads-with-a-form-rather-than-a-link.md |
| 0142 | 113 | 113-a-path-param-can-parse-itself.md |
| 0143 | 114 | 114-do-nothing-has-no-key-to-leave-out.md |
| 0144 | 115 | 115-a-boot-dials-the-connection-its-work-needs.md |
| 0145 | 116 | 116-a-raw-parameter-is-converted-the-way-a-rows-is.md |
| 0146 | 117 | 117-a-statement-that-failed-says-what-the-database-said.md |
| 0147 | 118 | 118-a-pattern-written-the-way-the-document-prints-it.md |
| 0148 | 051 | merged into 051-a-statement-that-is-a-constant-can-be-prepared-once.md |
| 0149 | 119 | 119-a-route-can-say-its-own-name.md |
| 0150 | 120 | 120-a-ctx-handler-that-returns-nothing-may-have-written-it.md |
| 0151 | 121 | 121-a-service-is-stopped-before-the-loop-is.md |
| 0152 | 122 | 122-the-panic-under-the-panic.md |
| 0153 | 123 | 123-a-migration-is-a-diff-against-a-snapshot.md |
| 0154 | 124 | 124-a-raw-statement-cannot-cast-what-it-did-not-write.md |
| 0155 | 125 | 125-a-row-that-owns-no-table.md |
| 0156 | 116 | merged into 116-a-raw-parameter-is-converted-the-way-a-rows-is.md |
| 0157 | 126 | 126-a-check-pays-for-its-own-branches.md |
| 0158 | 113 | merged into 113-a-path-param-can-parse-itself.md |
| 0159 | 127 | 127-what-a-server-prints-it-can-read.md |
| 0160 | 128 | 128-a-scope-that-can-mint-a-key.md |
| 0161 | 129 | 129-a-refusal-outside-a-request-is-still-a-refusal.md |
| 0162 | 130 | 130-a-table-this-program-reads-and-does-not-build.md |
| 0163 | 131 | 131-a-header-a-handler-can-be-given.md |
| 0164 | 132 | 132-a-query-parameter-or-a-form-field-that-is-a-list.md |
| 0165 | 133 | 133-a-value-that-reaches-the-bottom.md |
| 0166 | 134 | 134-entropy-a-function-pointer-can-carry.md |
| 0167 | 135 | 135-the-document-is-a-build-artefact.md |
| 0168 | 136 | 136-an-escape-hatch-that-costs-nothing-teaches-nothing.md |
| 0169 | 137 | 137-a-failed-assertion-that-can-be-read.md |
| 0170 | 138 | 138-a-test-does-not-need-the-optimiser.md |
| 0171 | 218 | merged into 218-a-row-may-carry-its-parent-its-children-or-a-sum.md |
| 0172 | 139 | 139-a-key-is-as-many-columns-as-it-takes.md |
| 0173 | 140 | 140-the-database-escapes-the-pattern-it-is-going-to-match.md |
| 0174 | 141 | 141-bytes-are-a-type-not-a-second-protocol.md |
| 0175 | 142 | 142-required-text-arrives-as-two-spaces.md |
| 0176 | 143 | 143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md |
| 0177 | 144 | 144-a-scope-that-crosses-a-function-pointer.md |
| 0178 | 145 | 145-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md |
| 0179 | 146 | 146-a-statement-with-a-key-in-it-has-a-single-row-answer.md |
| 0180 | 147 | 147-a-response-is-read-back-the-way-it-was-written.md |
| 0181 | 148 | 148-a-field-name-is-a-spelling-too.md |
| 0182 | 148 | merged into 148-a-field-name-is-a-spelling-too.md |
| 0183 | 149 | 149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md |
| 0184 | 117 | merged into 117-a-statement-that-failed-says-what-the-database-said.md |
| 0185 | 150 | 150-a-page-knows-what-it-left-out.md |
| 0186 | 151 | 151-a-key-is-named-once.md |
| 0187 | 109 | merged into 109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md |
| 0188 | 152 | 152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md |
| 0189 | 138 | merged into 138-a-test-does-not-need-the-optimiser.md |
| 0190 | 152 | merged into 152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md |
| 0191 | 153 | 153-an-authorization-header-a-handler-can-ask-for.md |
| 0192 | 154 | 154-a-health-route-asks-the-services.md |
| 0193 | 155 | 155-a-request-answered-once-is-answered-the-same-way-again.md |
| 0194 | 156 | 156-a-route-can-say-how-much-body-it-takes.md |
| 0195 | 157 | 157-a-type-can-write-its-own-answer.md |
| 0196 | 158 | 158-a-request-id-goes-out-with-the-call.md |
| 0197 | 159 | 159-a-server-past-its-limit-says-so-at-once.md |
| 0198 | 160 | 160-a-queue-is-a-table-in-the-database-you-already-have.md |
| 0199 | 161 | 161-a-schedule-is-a-type-that-makes-the-caller-choose.md |
| 0200 | 119 | merged into 119-a-route-can-say-its-own-name.md |
| 0201 | 162 | 162-a-middleware-can-learn-which-route-it-is-in-front-of.md |
| 0202 | 163 | 163-a-document-is-its-value.md |
| 0203 | 164 | 164-a-value-coerces-into-a-nullable-column-and-an-error-union-does-not.md |
| 0204 | 165 | 165-an-order-chosen-at-run-time-from-a-closed-set.md |
| 0205 | 166 | 166-a-body-field-that-parses-itself.md |
| 0206 | 167 | 167-a-whole-number-inside-a-range-is-a-type.md |
| 0207 | 168 | 168-one-field-can-be-spelled-on-its-own.md |
| 0208 | 169 | 169-a-statement-pays-for-the-width-of-its-row.md |
| 0209 | 170 | 170-a-document-names-every-shape-it-has.md |
| 0210 | 171 | 171-an-answer-knows-which-request-it-was.md |
| 0211 | 172 | 172-one-condition-over-several-columns-is-one-parameter.md |
| 0212 | 173 | 173-bytes-handed-on-are-an-answer.md |
| 0213 | 174 | 174-the-body-decides-not-the-method.md |
| 0214 | 175 | 175-an-exists-reads-the-reference-from-either-side.md |
| 0215 | 176 | 176-an-answer-with-no-body-ends-at-its-head.md |
| 0216 | 177 | 177-a-presigned-url-names-the-host-the-browser-reaches.md |
| 0217 | 178 | 178-a-row-can-carry-a-field-no-column-holds.md |
| 0218 | 179 | 179-a-run-can-say-its-failure-is-final.md |
| 0219 | 144 | merged into 144-a-scope-that-crosses-a-function-pointer.md |
| 0220 | 180 | 180-work-that-needs-the-services-runs-on-their-loop.md |
| 0221 | 181 | 181-the-marker-has-two-kinds-of-word.md |
| 0222 | 181 | merged into 181-the-marker-has-two-kinds-of-word.md |
| 0223 | 123 | merged into 123-a-migration-is-a-diff-against-a-snapshot.md |
| 0224 | 181 | merged into 181-the-marker-has-two-kinds-of-word.md |
| 0225 | 181 | merged into 181-the-marker-has-two-kinds-of-word.md |
| 0226 | 181 | merged into 181-the-marker-has-two-kinds-of-word.md |
| 0227 | 123 | merged into 123-a-migration-is-a-diff-against-a-snapshot.md |
| 0228 | 041 | merged into 041-core-knows-what-time-it-is.md |
| 0229 | 160 | merged into 160-a-queue-is-a-table-in-the-database-you-already-have.md |
| 0230 | 056 | merged into 056-the-way-out-was-open-the-clock-was-not.md |
| 0231 | 182 | 182-a-header-std-owns-goes-out-once.md |
| 0232 | 183 | 183-a-redirect-is-a-decision-with-a-name.md |
| 0233 | 123 | merged into 123-a-migration-is-a-diff-against-a-snapshot.md |
| 0234 | 125 | merged into 125-a-row-that-owns-no-table.md |
| 0235 | 184 | 184-a-caller-that-knows-says-discard.md |
| 0236 | 185 | 185-the-reference-is-a-folder-one-page-a-module.md |
| 0237 | 056 | merged into 056-the-way-out-was-open-the-clock-was-not.md |
| 0238 | 186 | 186-the-transfer-buffer-serves-nothing-here.md |
| 0239 | 183 | merged into 183-a-redirect-is-a-decision-with-a-name.md |
| 0240 | 187 | 187-a-head-that-outlives-its-body.md |
| 0241 | 044 | merged into 044-a-password-hash-is-gated-because-forgetting-is-silent.md |
| 0242 | 111 | merged into 111-nilo-verifies-a-token-and-does-not-fetch-one.md |
| 0243 | 061 | merged into 061-a-fitting-borrows-the-loop.md |
| 0244 | 187 | merged into 187-a-head-that-outlives-its-body.md |
| 0245 | 160 | merged into 160-a-queue-is-a-table-in-the-database-you-already-have.md |
| 0246 | 160 | merged into 160-a-queue-is-a-table-in-the-database-you-already-have.md |
| 0247 | 188 | 188-a-route-can-say-cache-this-answer-for-a-minute.md |
| 0248 | 043 | merged into 043-a-deadline-needs-a-connection-you-hold.md |
| 0249 | 009 | merged into 009-static-files-are-held-in-memory-or-opened.md |
| 0250 | 058 | merged into 058-most-of-an-s3-client-is-not-s3.md |
| 0251 | 089 | merged into 089-a-body-under-an-encoding-other-than-gzip-is-refused.md |
| 0252 | 153 | merged into 153-an-authorization-header-a-handler-can-ask-for.md |
| 0253 | 181 | merged into 181-the-marker-has-two-kinds-of-word.md |
| 0254 | 061 | merged into 061-a-fitting-borrows-the-loop.md |
| 0255 | 111 | merged into 111-nilo-verifies-a-token-and-does-not-fetch-one.md |
| 0256 | 132 | merged into 132-a-query-parameter-or-a-form-field-that-is-a-list.md |
| 0257 | 160 | merged into 160-a-queue-is-a-table-in-the-database-you-already-have.md |
| 0258 | 189 | 189-a-version-a-handler-names-is-an-etag.md |
| 0259 | 190 | 190-a-restart-on-save-watches-the-binary-not-the-sources.md |
| 0260 | 191 | 191-verified-claims-are-a-handler-argument.md |
| 0261 | 109 | merged into 109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md |
| 0262 | 192 | 192-a-db-with-no-schema-check-says-so-or-is-told.md |
| 0263 | 055 | merged into 055-the-second-dialect-is-the-test-of-the-seam.md |
| 0264 | 193 | 193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md |
| 0265 | 194 | 194-an-accept-loop-that-is-out-of-descriptors-waits.md |
| 0266 | 195 | 195-a-refused-request-is-hung-up-on-with-a-fin.md |
| 0267 | 105 | merged into 105-a-route-can-say-how-long-it-has.md |
| 0268 | 196 | 196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md |
| 0269 | 197 | 197-a-response-says-when-it-was-sent.md |
| 0270 | 024 | merged into 024-every-failure-answers-as-json.md |
| 0271 | 198 | 198-a-backlog-is-sized-for-the-burst-not-the-load.md |
| 0272 | 199 | 199-a-connection-is-served-by-the-thread-it-was-dealt-to.md |
| 0273 | 200 | 200-every-executor-accepts.md |
| 0274 | 201 | 201-a-response-is-flushed-before-the-connection-waits.md |
| 0275 | 202 | 202-a-reset-between-frames-is-a-client-that-has-gone.md |
| 0276 | 203 | 203-a-question-mark-goes-inside-the-wrapper.md |
| 0277 | 180 | merged into 180-work-that-needs-the-services-runs-on-their-loop.md |
| 0278 | 204 | 204-a-raw-placeholder-is-spelled-for-the-dialect.md |
| 0279 | 205 | 205-a-raw-statement-can-carry-its-total.md |
| 0280 | 206 | 206-a-statement-that-always-answers-answers-a-row.md |
| 0281 | 120 | merged into 120-a-ctx-handler-that-returns-nothing-may-have-written-it.md |
| 0282 | 207 | 207-a-try-call-hands-back-the-error-and-says-nothing.md |
| 0283 | 208 | 208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md |
| 0284 | 115 | merged into 115-a-boot-dials-the-connection-its-work-needs.md |
| 0285 | 209 | 209-a-verified-signature-is-remembered-by-the-tokens-digest.md |
| 0286 | 210 | 210-a-services-wait-on-its-own-socket-is-a-park.md |
| 0287 | 211 | 211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md |
| 0288 | 212 | 212-tls-is-an-option-a-build-asks-for.md |
| 0289 | 213 | 213-a-server-answers-on-more-than-one-address.md |
| 0290 | 214 | 214-a-job-says-how-urgent-it-is.md |
| 0291 | 215 | 215-a-worker-claims-only-what-it-can-run.md |
| 0292 | 216 | 216-a-message-that-arrived-whole-is-handed-over-where-it-lies.md |
| 0293 | 217 | 217-a-handshakes-signature-is-computed-off-the-executor.md |
| 0294 | 212 | merged into 212-tls-is-an-option-a-build-asks-for.md |
| 0295 | 218 | 218-a-row-may-carry-its-parent-its-children-or-a-sum.md |
| 0296 | 219 | 219-the-guide-is-published-once-a-release.md |
| 0297 | 220 | 220-grpc-is-served-over-h2c-behind-a-flag.md |
