# Flogi Database (flogi_db) - 개발 및 리팩토링 가이드 (상세)

**최종 업데이트:** 2025년 5월 27일
**문서 버전:** 1.0
**레포지토리:** `https://github.com/flogi-dev/flogi_db` (실제 URL로 업데이트 필요)
**관련 문서:**
* [Comfort Commit 시스템 설계서 (전체 시스템)](./README.md)
* [Gemini 데이터 구조 설계자 지침서 (DB 역할 정의)] (별도 문서 또는 이 문서에 통합)
* [DB 스키마 디렉토리 (`00_DB/main/schema/`)](source_file_DB_schema_directory)

---

## 🎯 1. Flogi DB 프로젝트 철학 및 핵심 목표

**"모든 로직은 결국 테이블로 돌아온다. 당신은 그 시작점이자, 모든 커밋의 기억을 조율하는 구조의 연금술사다.”**

Flogi DB는 "Comfort Commit" 시스템의 핵심 데이터 영속화 계층입니다. 사용자의 코드 변경 활동에서부터 AI 기반 커밋 메시지 생성, 최종 승인, 알림, 그리고 이 모든 과정에서 발생하는 로그와 임베딩 데이터에 이르기까지, 시스템의 모든 "기억"을 구조화된 형태로 저장하고 관리하는 것을 목표로 합니다.

**Flogi DB의 핵심 목표는 다음과 같습니다:**

1.  **사용자 행위의 포괄적 영속화:**
    * 코드 변경, 커밋 메시지 생성 요청, AI 초안, 사용자 수정 및 최종 승인까지의 전 과정을 추적하고 기록합니다.
    * 사용자 알림 설정, 실제 발송된 알림, 사용자의 피드백 등 서비스 운영에 필요한 모든 상호작용을 데이터로 남깁니다.
2.  **정책 기반의 데이터 모델 구축:**
    * 사용자 요금제(`plan_catalog`, `user_plan`, `user_plan_history`)를 중심으로 기능 접근 권한, 사용량 제한, 데이터 보존 정책 등을 DB 레벨에서 명확히 정의하고 관리합니다.
    * 이는 `@enforce_limit()`, `@track_tokens()`와 같은 핵심 로직의 자동화된 의사결정 기준점을 제공합니다.
3.  **AI 및 분석 시스템의 핵심 참조 지점 역할:**
    * 커밋 메시지 및 코드 요소에 대한 임베딩 벡터(`code_element_embeddings`)를 요금제별 정책에 따라 저장하고, 유사도 판단의 기준을 제공합니다.
    * LLM 호출 로그(`llm_request_log`)를 통해 토큰 사용량, 비용 등을 집계하고, 향후 모델 개선 및 비용 최적화의 기반 데이터를 마련합니다.
4.  **데이터 무결성, 보안, 확장성 확보:**
    * 명확한 PK-FK 관계, 제약 조건, 트랜잭션 관리를 통해 데이터 무결성을 보장합니다.
    * 민감 정보(예: `user_secret`)는 암호화 또는 외부 보안 저장소 참조를 원칙으로 하며, Row-Level Security (RLS) 및 역할 기반 접근 제어(RBAC) 연동을 통해 데이터 접근 보안을 강화합니다.
    * 로그 데이터 파티셔닝, JSONB의 유연한 활용, 비동기 처리 등을 통해 시스템 확장성을 고려합니다.

**Flogi DB 설계자는 단순한 테이블 설계자가 아닌, 시스템의 논리, 정책, 비용, 행동, 보안을 하나의 일관된 데이터 구조로 엮어내는 "구조의 연금술사"입니다.** 이 README는 그 여정을 위한 나침반이 될 것입니다.

## 🚀 2. 현황 진단 및 리팩토링 방향

현재 Flogi DB는 시스템의 핵심 기능을 지원하기 위한 초기 스키마 구축이 `00_common`부터 `04_repo` 모듈까지 진행된 상태입니다. 이는 "Comfort Commit"의 사용자 인증, LLM 연동, 요금제 관리, 그리고 가장 복잡한 저장소 및 코드 분석 데이터 처리를 위한 기반을 마련한 것입니다.

하지만 시스템의 안정적 성장과 유지보수성 향상, 그리고 "Gemini 데이터 구조 설계자 지침서" 및 "Comfort Commit 시스템 설계서" 와의 완벽한 정합성을 위해 다음과 같은 리팩토링 목표와 방향을 설정합니다.

### 2.1. 주요 리팩토링 목표 (High-Level Refactoring Goals)

1.  **설계 문서와의 완벽한 동기화:**
    * "Gemini 데이터 구조 설계자 지침서" 및 "Comfort Commit 시스템 설계서" (특히 `plan_catalog` 정의, 필수 테이블 목록, 보안 요구사항, 임베딩 전략 등) 와 현재 스키마 간의 불일치 해소.
    * 용어 및 명명 규칙 통일.
2.  **데이터 모델 일관성 및 정합성 강화:**
    * **식별자(PK, FK) 전략 표준화:** `uuid` (내부용, `SERIAL` 또는 `BIGSERIAL`)와 `id` (외부 공개용, `gen_random_id()` 또는 `UUID`) 사용 전략을 명확히 하고 전 테이블에 일관되게 적용. 현재 `UUID` 타입과 `uuid-ossp` 확장이 권장되므로 `id UUID PRIMARY KEY DEFAULT uuid_generate_v4()`를 표준으로 고려.
    * **ENUM 타입 관리 중앙화 및 표준화:** `00_01_enums_and_types.sql` 및 모듈별 `00_XX_enums_and_types.sql` 파일의 ENUM 정의를 검토하고, 시스템 전체에서 사용될 공통 ENUM과 모듈 특화 ENUM을 명확히 구분. 값의 일관성 및 완전성 확보.
    * **참조 무결성 강화:** `ON DELETE` 정책(CASCADE, SET NULL, RESTRICT) 검토 및 명확화. 누락된 FK 제약 조건 추가.
3.  **핵심 기능 지원을 위한 스키마 보강:**
    * **`embedding_cache` 구현:** 지침서에 명시된 `embedding_cache` 테이블 (커밋 메시지 임베딩 + 유사도 점수 저장, `plan_key` 기준 필드 선택)의 구체적인 설계 및 구현. 현재 `code_element_embeddings`와 역할 분담 또는 통합 방안 명확화.
    * **`biz_event` 테이블 설계:** 승인/알림 등 주요 비즈니스 행동 로그를 위한 `biz_event` 테이블 설계. `user_action_log` 또는 `finalized_commits` 와의 관계 정립.
    * **`token_usage_log` 기능 확인:** `llm_request_log`가 지침서의 `token_usage_log` 역할을 완전히 수행하는지, 특히 `trace_uuid` 연동 (현재 `request_correlation_uuid`) 부분을 명확히 하고 필요시 보완.
4.  **성능 및 확장성 개선:**
    * **인덱싱 전략 최적화:** 모든 테이블에 대한 조회 패턴 분석 기반의 최적 인덱스(B-tree, GIN, GiST, BRIN 등) 적용. 특히 JOIN 컬럼, WHERE절 자주 사용 컬럼, JSONB 내부 경로, `pgvector` HNSW 인덱스 설정 검토.
    * **파티셔닝 전략 구체화:** `user_action_log`, `llm_request_log` 등 대용량 로그 테이블의 파티셔닝 키, 범위, 관리 방안(예: `pg_partman` 도입) 구체화.
    * **데이터 보관 및 TTL 정책 반영:** `user_plan.pii_data_retention_days` 등 정책 필드와 연계된 실제 데이터 삭제/아카이빙 로직 지원을 위한 스키마 구조 검토.
5.  **보안 강화 조치 구체화:**
    * **컬럼 암호화 적용:** 지침서에 명시된 `refresh_token`, `payment_info` 등의 AES-256-GCM 암호화 대상 필드 식별 및 `pgcrypto` 등을 이용한 암호화/복호화 인터페이스 또는 애플리케이션 레벨 처리 방안 명시. (`user_secret` 테이블의 현재 메타데이터 관리 방식은 좋으나, 실제 암호화된 값 저장 컬럼이 필요하다면 `BYTEA` 타입 추가 등)
    * **RLS (Row-Level Security) 정책 정의:** `repo_access_permissions` 등 주요 테이블에 대한 구체적인 RLS 정책 초안 작성.
    * **RBAC 연동 스키마 구체화:** 지침서의 `action_map` 등 RBAC 연동을 위한 DB 스키마 지원 방안 구체화.

### 2.2. 모듈별 주요 리팩토링 및 개발 항목

#### 2.2.1. `00_common_functions_and_types.sql` / `00_01_enums_and_types.sql`

* **`id` 타입 재정의 및 표준화:** 현재 `gen_random_id()`로 정의된 `id` 타입과 `SERIAL`/`BIGSERIAL`로 정의된 `uuid` 컬럼의 혼용 문제를 해결. `uuid-ossp` 확장의 `uuid_generate_v4()`를 사용하는 `UUID` 타입을 PK 표준으로 채택하는 것을 적극 권장. `gen_random_id()`는 공개용 식별자(예: `public_id`) 생성 함수로 역할을 명확히 할 수 있음.
* **ENUM 정의 일관성 및 완전성 확보:**
    * 전체 시스템에서 사용되는 ENUM 값들을 검토하고, 누락되거나 모호한 부분 수정. (예: `plan_key_enum` 값들이 `plan_catalog` 실제 키값과 일치하는지)
    * 모듈별 ENUM 파일(`00_XX_enums_and_types.sql`)과 글로벌 ENUM 파일의 역할 분담 명확화.
* **공통 함수 검토:**
    * `set_updated_at()`: 모든 테이블에 일관되게 적용되고 있는지 확인.
    * `delete_expired_sessions()`, `expire_rewards()`: 로직 정확성 및 스케줄링 방안 검토.
    * `insert_user_plan_history_trigger_function()`: `plan_catalog` 연동 및 `user_plan_history`의 모든 컬럼(특히 스냅샷 값)을 정확히 채울 수 있도록 로직 보강. `current_setting('comfort_commit.actor_id', TRUE)`를 통한 행위자 추적 방식의 안정성 및 활용 방안 검토.

#### 2.2.2. `01_user` 모듈

* `user_info`: `uuid` (SERIAL)와 `id` (id 타입) 컬럼의 역할 및 타입 명확화 (예: `internal_id BIGSERIAL PRIMARY KEY`, `public_id UUID UNIQUE DEFAULT uuid_generate_v4()`). `oauth_links`, `account_links` JSONB 구조 상세화 및 실제 사용 사례 기반 필드 정의.
* `user_oauth`: 각 `*_uuid` 컬럼에 `UNIQUE` 제약 조건이 이미 설정되어 있으나, OAuth 제공자별로 이메일이 중복될 수 있는 경우(`*_email`)에 대한 처리 정책 고려.
* `user_session`: `access_token_ref`, `refresh_token_ref`가 실제 토큰이 아닌 참조값임을 명확히 하고, 참조 대상(Redis 키 패턴 등)에 대한 구체적인 명명 규칙 정의. `device_uuid`의 생성 및 관리 주체 명확화.
* `user_secret`: `api_keys_meta`, `oauth_tokens_meta` JSONB 내부 스키마를 더욱 구체화하고, 지침서의 AES256 암호화 요구사항에 따라 실제 암호화된 값을 저장해야 할 경우(권장하지 않음) 또는 암호화된 키 참조를 저장할 경우를 위한 컬럼(`*_enc BYTEA`, `enc_iv BYTEA`) 추가 고려.
* `user_action_log`: 파티션 키(`created_at`) 관리 전략(자동 생성, 보관 주기 등) 구체화. `external_metadata_ref_uuid`의 참조 대상(Loki 스트림 ID, S3 Object ID 등) 및 형식 정의.
* `user_deletion_request`: `processing_log` JSONB 구조 구체화.

#### 2.2.3. `02_llm` 모듈

* `llm_key_config`: `api_key_reference`의 구체적인 참조 방식(Vault 경로, 환경 변수명 패턴 등) 명확화. `rpm_limit`, `tpm_limit` 외 추가적인 제약 조건(예: 분당 토큰 생성량 제한) 필요 여부 검토.
* `llm_request_log`:
    * 파티션 관리 전략 구체화.
    * `prompt`, `completion` 컬럼의 PII 마스킹 및 길이 제한 정책 수립. 스케일업 시 외부 저장(Loki/S3) 전환 계획 및 `external_prompt_ref_uuid`, `external_completion_ref_uuid` 컬럼 추가 고려.
    * `request_correlation_uuid`가 "Gemini 지침서"의 `trace_uuid` 역할을 수행하는지 명확히 하고, 필요시 컬럼명 변경 또는 별도 `trace_uuid` 컬럼 추가 고려.
    * `cost_usd` 계산 로직의 정확성 및 환율 처리 방안(필요시) 검토.

#### 2.2.4. `03_plan_reward` 모듈

* `user_plan`:
    * `plan_catalog` 테이블과의 관계 명확화: `plan_label`, `monthly_price_usd` 등 중복 가능성 있는 정보는 `plan_catalog`에서 JOIN하여 사용하는 것을 원칙으로 하고, `user_plan`에는 `plan_key`만 저장하는 방안 검토. (현재 스키마는 일부 중복 저장)
    * 기능 플래그 (`slack_integration_enabled` 등 다수 BOOLEAN 컬럼): 컬럼 수가 많아질 경우 JSONB (`feature_flags JSONB`) 또는 별도의 `user_plan_features` 테이블로 정규화하는 방안 검토.
    * `plan_key_enum` 값들과 `plan_catalog` 시딩 데이터 간의 완전한 일치 확인 (특히, `README.md`의 `plan_catalog` 정의와 실제 DB 스키마 간 필드 불일치 해소 - 예: `max_describes_per_month` 등).
* `user_plan_history`: 트리거 함수(`insert_user_plan_history_trigger_function`)가 `plan_catalog`의 최신 정보를 참조하여 `old_plan_label`, `new_plan_label`, `old_price_usd`, `new_price_usd`, `is_new_plan_team_plan` 등을 정확히 채우도록 수정. `commit_usage_snapshot` 등 스냅샷 컬럼 채우는 로직 구체화 (애플리케이션 레벨 또는 복잡한 트리거).
* `user_reward_log`: `trigger_type`, `reward_type`을 ENUM으로 변경하거나, 별도 마스터 테이블(`reward_trigger_master`, `reward_item_master`)로 분리하여 관리하는 방안 검토.

#### 2.2.5. `04_repo` 모듈

* **파일 정리:** `00_DB/main/schema/04_repo/repo.sql` 파일은 현재 여러 다른 SQL 파일의 내용을 포함하고 있는 것으로 보입니다. 이 파일의 역할을 명확히 하고, 중복 내용을 제거하거나 각 모듈별 파일 및 `00_04_enums_and_types.sql` 로 내용을 이전하여 단일 책임 원칙을 지키도록 합니다.
* **ENUM 타입 관리:** `00_04_enums_and_types.sql` 파일에 `04_repo` 모듈 전반에서 사용될 ENUM 타입을 통합 관리하고, 각 테이블에서는 이 ENUM을 참조하도록 합니다. (현재 일부 ENUM이 `repo.sql`에 중복 정의된 것으로 보임)
* **`01_repo_main`**
    * `repo_main`: `owner_id`와 `user_info.id`의 관계 명확화. `remote_url` 외 추가적인 고유 식별자(예: 플랫폼별 ID) 필요 여부 검토.
    * `repo_connections`: `comfort_commit_config_json`의 내부 스키마 정의 및 예시 제공. `access_token_ref_uuid` 관리 방안 구체화.
    * `repo_access_permissions`: RLS 적용 필수 테이블. `access_level` ENUM 값의 구체적인 권한 범위 정의.
* **`02_code_snapshots`**
    * `code_snapshots`: `analysis_status_enum` 값 세분화 및 각 상태별 전환 로직 정의.
    * `directory_structures`: `tree_structure_json` 필드의 구체적인 용도와 스키마 정의. 계층 구조 쿼리 성능 최적화 (예: `ltree` 타입 사용 고려).
    * `file_diff_fragments` (파일명 `03_file_diff_fragmt.sql`로 되어 있으나 `file_diff_fragments`가 더 명확): `snapshot_file_uuid`는 `snapshot_file_instances.snapshot_file_uuid`를 참조하도록 FK 관계 명확화. `raw_diff_content` 저장 정책(크기 제한, PII 필터링) 및 `external_diff_storage_url` 활용 방안 구체화.
* **`03_files`**
    * `file_uuidentities`: 파일 "정체성" 추적을 위한 핵심 테이블. `initial_file_path` 외에 `initial_content_hash` 추가하여 내용 기반 정체성 식별 강화 고려.
    * `snapshot_file_instances`: `file_content_hash` 생성 방식 및 알고리즘 표준화. `detected_language` ENUM 값 범위 확장 고려. `change_type_from_parent_snapshot` ENUM 값 정의 및 결정 로직 명확화.
    * `file_analysis_metrics`: `metric_type_enum` 값 확장 및 각 메트릭의 구체적인 계산 방법 또는 참조 도구 명시. `metric_value_json`의 스키마 유연성과 쿼리 성능 간의 균형 고려.
* **`04_code_elements`**
    * `code_element_uuidentities`: `element_uuidentifier` 생성 규칙 고도화 (단순 경로+이름 외 시그니처 해시, AST 구조 기반 등). `semantic_hash` 도입 적극 검토.
    * `snapshot_code_element_instances`: `code_content_snippet` 저장 범위 및 PII 필터링 정책. `metadata` JSONB에 저장될 정보의 표준 스키마 정의 (예: AST 노드 타입, 복잡도 지표). `previous_element_instance_id`를 통한 코드 요소 변경 추적 로직 구체화.
    * `code_element_relations`: `relation_type_enum` 값 상세화 및 각 관계 타입의 분석 방법(`analysis_method`) 명시. `properties` JSONB 필드 활용 예시 구체화.
    * `code_element_embeddings`:
        * **가장 시급한 리팩토링 대상 중 하나.** "Gemini 지침서"의 요금제별 벡터 모델/차원 분기 정책(`code2vec` 512차원 vs `text-embedding-3` 1536차원)을 반영해야 함.
        * 현재 `embedding_vector VECTOR(1536)`은 모든 요금제에 대해 1536차원을 강제하므로, `embedding_code2vec VECTOR(512)` 와 `embedding_bert VECTOR(1536)` 컬럼을 분리하거나, `embedding_model_name`에 따라 사용하는 컬럼을 동적으로 선택하는 로직 필요.
        * `pgvector` HNSW 인덱스 생성 시 `lists` (IVFFlat의 경우) 또는 `M`, `ef_construction` (HNSW의 경우) 파라미터 최적화. (`ef=200` 유지 지침).
        * `embedding_architecture.md` 문서에 언급된 "운영 DB와 임베딩 DB 분리", "버전 단위 누적 저장" (`code_element_embedding_versions` 테이블) 전략을 현재 스키마와 비교하여 일관성 확보 및 최종 결정. `code_element_embeddings`는 최신 벡터, `code_element_embedding_versions`는 모든 버전 누적 저장이 합리적으로 보임.
* **`05_commit_gen`**
    * `commit_generation_requests`: `context_references_json` 필드에 저장되는 각 참조 ID들의 대상 테이블 및 의미 명확화 (주석 및 문서화 강화). 각 FK들이 해당 테이블 생성 후 `ALTER TABLE`로 정확히 연결되도록 관리.
    * `generated_commit_contents`: `llm_request_log_uuid`를 `llm_request_log.uuid` (BIGINT) 타입과 일치시키고 FK 설정. `commit_message_full` 생성 로직(템플릿 적용 등) 명시.
    * `finalized_commits`: `git_commit_sha`, `git_push_status` 등 Git 연동 후 업데이트될 필드들의 처리 흐름 정의. `approval_source` 값들의 표준화.
    * `scoping_results`: `scoping_run_uuid`를 통해 특정 요청의 여러 스코핑 시도들을 그룹화하고, `commit_generation_requests.scoping_result_uuid`에서 이를 참조하도록 관계 명확화. `scoping_method` 값 표준화.
    * `generated_technical_descriptions`: `llm_request_log_uuid` 타입 일치 및 FK 설정. `content_format` (markdown, plaintext 등) ENUM화 고려.
    * `llm_input_context_details`: `context_element_reference_uuid`가 참조하는 실제 테이블이 `context_element_type`에 따라 동적으로 변경되므로, 애플리케이션 레벨에서의 타입 확인 및 유효성 검증 로직 중요.

---

## 🗂️ 3. Schema Structure and Conventions (Deep Dive)

Flogi DB의 일관성과 유지보수성을 극대화하기 위해 명확한 구조와 규칙을 따릅니다. 이는 "Comfort Commit 시스템 설계서" 및 "Gemini 데이터 구조 설계자 지침서"의 원칙을 반영합니다.

### 3.1. Directory Structure (`00_DB/main/schema/`)

모든 DB 스키마 정의 파일(테이블, 타입, 함수, 트리거 등)은 `00_DB/main/schema/` 하위에 모듈별로 그룹화됩니다.

00_DB/
└── main/
├── schema/
│   ├── 00_01_enums_and_types.sql       # Global ENUMs, custom types (예: id 타입)
│   ├── 00_common_functions_and_types.sql # Global functions, triggers (예: set_updated_at)
│   │
│   ├── 01_user/                        # 사용자 정보 및 활동 관련 모듈
│   │   ├── 01_info.sql                 # user_info 테이블
│   │   ├── 02_oauth.sql                # user_oauth 테이블
│   │   ├── ... (03_session.sql ~ 10_del_req.sql)
│   │
│   ├── 02_llm/                         # LLM 연동 및 로그 관련 모듈
│   │   ├── 01_key_config.sql           # llm_key_config 테이블
│   │   ├── 02_request_log.sql          # llm_request_log 테이블
│   │
│   ├── 03_plan_reward/                 # 요금제, 구독, 보상 관련 모듈
│   │   ├── 01_plan.sql                 # user_plan, plan_catalog (시딩 데이터는 별도 관리 또는 주석으로 명시)
│   │   ├── 02_history.sql              # user_plan_history 테이블
│   │   ├── 03_reward_log.sql           # user_reward_log 테이블
│   │
│   ├── 04_repo/                        # 저장소, 코드 분석, 커밋 생성 흐름 관련 모듈
│   │   ├── 00_04_enums_and_types.sql   # Repo 모듈 특화 ENUMs, custom types
│   │   ├── 01_repo_main/               # 저장소 기본 정보 및 연결
│   │   │   ├── 01_main.sql             # repo_main 테이블
│   │   │   ├── 02_connections.sql      # repo_connections 테이블
│   │   │   └── 03_access_permissions.sql # repo_access_permissions 테이블
│   │   ├── 02_code_snapshots/          # 코드 스냅샷 및 디렉토리 구조
│   │   │   ├── 01_code_snapshots.sql
│   │   │   ├── 02_dir_structures.sql
│   │   │   └── 03_file_diff_fragmt.sql # (파일명 정정: file_diff_fragments.sql 권장)
│   │   ├── 03_files/                   # 파일 식별자, 스냅샷별 파일 인스턴스, 분석 메트릭
│   │   │   ├── 01_identities.sql       # file_uuidentities 테이블
│   │   │   ├── 02_snapshot_inst.sql    # snapshot_file_instances 테이블
│   │   │   └── 03_analysis_metrics.sql # file_analysis_metrics 테이블
│   │   ├── 04_code_elements/           # 코드 요소 식별자, 인스턴스, 관계, 임베딩
│   │   │   ├── 01_elements_identities.sql
│   │   │   ├── 02_elements_snapshot_inst.sql
│   │   │   ├── 03_elements_relations.sql
│   │   │   └── 04_elements_embeddings.sql # code_element_embeddings, code_element_embedding_versions 테이블
│   │   └── 05_commit_gen/              # 커밋 생성 요청부터 최종 확정까지의 흐름
│   │       ├── 01_gen_requests.sql
│   │       ├── 02_gen_contents.sql
│   │       ├── 03_finalized_commits.sql
│   │       ├── 04_scoping_results.sql
│   │       ├── 05_gen_description.sql
│   │       └── 06_input_context_details.sql
│   │
│   ├── XX_module_name/                 # 향후 추가될 모듈 (예: 05_billing, 06_analytics)
│   │   └── ...
│   │
│   └── _archive/                       # (선택적) 더 이상 사용되지 않지만 참고용으로 보관하는 스키마 파일
│
├── data_only/                          # (선택적) 초기 데이터 시딩(Seeding) 스크립트 (예: plan_catalog 초기값)
│   └── 01_seed_plan_catalog.sql
│
└── cache/                              # (버전 관리 대상 아님) 로컬 DB 파일 저장 위치 (gitignore 처리)
└── ...


**참고:** `00_DB/main/schema/04_repo/repo.sql` 파일은 현재 여러 SQL 파일의 내용을 포함하고 있는 것으로 보입니다. 리팩토링 과정에서 이 파일의 내용을 각 해당 모듈 파일 및 `00_04_enums_and_types.sql`로 이전하고, `repo.sql` 파일 자체는 제거하거나 모듈 로딩 순서만을 정의하는 등의 다른 명확한 용도로 변경해야 합니다.

### 3.2. Naming Conventions (명명 규칙)

일관된 명명 규칙은 스키마의 가독성과 예측 가능성을 높입니다.

* **Modules (디렉토리명):** `[두 자리 숫자 순번]_[모듈_기능_영문명_소문자_스네이크_케이스]` (예: `01_user`, `04_repo`).
* **SQL Files:**
    * 테이블 정의: `[두 자리 숫자 순번]_[테이블_주요_내용_영문명_소문자_스네이크_케이스].sql` (예: `01_info.sql`, `02_connections.sql`). 순번은 논리적 그룹핑 및 로딩 순서 고려.
    * 모듈별 ENUM/Type: `00_[모듈순번]_[enums_and_types].sql` (예: `00_04_enums_and_types.sql`).
* **Tables:** `[모듈_약자_혹은_전체명]_[내용_묘사_영문명_소문자_스네이크_케이스]` (일반적으로 복수형 권장). 테이블명은 최대한 해당 테이블이 담고 있는 데이터의 내용을 명확히 나타내도록 합니다. 모듈 약자 사용은 일관성을 유지한다면 허용 (예: `usr_info` 보다는 `user_info` 또는 `users` 권장). Flogi DB 현재 스키마는 모듈명을 직접 사용하지 않는 경향이 있으나, 테이블 수가 매우 많으므로 가독성을 위해 접두어 사용을 고려할 수 있습니다. (예: `user_profiles` 대신 `user_info` 사용 중).
    * 예시: `user_info`, `user_sessions`, `repo_main`, `code_snapshots`, `llm_request_logs`.
* **Columns:** `[영문명_소문자_스네이크_케이스]`.
    * **Primary Keys (PKs):** **`uuid UUID`** 를 표준으로 채택. (예: `uuid UUID PRIMARY KEY DEFAULT uuid_generate_v4()`). 기존 `id` (custom type `id`), `uuid` (`SERIAL` 또는 `BIGSERIAL`) 컬럼은 이 표준으로 통일. 만약 특정 테이블에서 공개용, 예측 불가능한 짧은 ID가 필요하다면 `public_id TEXT UNIQUE DEFAULT gen_random_id('prefix_', 16)` 와 같이 별도 컬럼으로 정의.
    * **Foreign Keys (FKs):** `[참조하는_테이블_단수명]_uuid` (예: `user_uuid`, `repo_uuid`, `snapshot_uuid`). 참조하는 PK 컬럼명이 `uuid`가 아닌 경우(예: `public_id`) 그 컬럼명을 따름 (`[참조테이블명]_public_id`).
    * **Timestamps:** `created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP`, `updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP`. 필요한 경우 `deleted_at TIMESTAMPTZ` (Soft Delete).
    * **Booleans:** 긍정적 상태를 나타내는 이름 사용. (예: `is_active`, `is_enabled`, `is_verified`, `has_feature_xyz`). `NOT NULL DEFAULT FALSE` 또는 `NOT NULL DEFAULT TRUE` 명시.
    * **ENUM Types (컬럼명):** 내용 묘사 후 `_type` 또는 `_status` (예: `account_type`, `request_status`, `plan_key`).
    * **ENUM Type Names (PostgreSQL 타입명):** `[내용_묘사]_enum` (예: `user_account_type_enum`, `plan_key_enum`).
    * **JSONB Columns:** 내용물 명시 후 `_json` 또는 `_config_json`, `_data_json` 등 (예: `metadata_json`, `alert_configurations_json`).
* **Functions & Triggers:** `[동사_목적어_스네이크_케이스]`.
    * Triggers: `trg_[테이블명_변경전후상태_이벤트]` (예: `trg_user_plan_before_update_log_history`). 현재 `set_updated_at()` 함수를 호출하는 트리거는 `[테이블명]_set_updated_at_trigger`.
    * Functions: `fn_[주요_동작_묘사]` (예: `fn_calculate_similarity_score`, `fn_get_user_active_plan`). 현재 `gen_random_id()`, `set_updated_at()` 등.
* **Indexes:** `idx_[테이블명]_[컬럼명(들)]_[인덱스_타입_약자(선택)]`. 여러 컬럼일 경우 `__`로 구분.
    * 예: `idx_user_info_email`, `idx_code_snapshots_repo_uuid_git_commit_hash_uniq`, `idx_embeddings_vector_hnsw`.
* **Constraints:** `chk_[테이블명]_[조건_묘사]`, `fk_[현재테이블명]_[참조테이블명]_[참조컬럼명(들)]`, `uq_[테이블명]_[컬럼명(들)]`.
    * PostgreSQL은 제약조건명을 자동으로 생성하지만, 명시적으로 지정하면 관리 및 디버깅에 용이.

### 3.3. Data Types (데이터 타입)

적절한 데이터 타입 선택은 데이터 무결성, 저장 공간 효율성, 성능에 중요합니다.

* **Primary Keys:** `UUID` (`uuid-ossp` 확장의 `uuid_generate_v4()` 사용).
* **Foreign Keys:** 참조하는 PK의 데이터 타입과 일치 (`UUID`).
* **Identifiers (Public):** `TEXT` 또는 `VARCHAR`. 필요시 `gen_random_id()` 함수 (prefix, 길이 지정 가능하게 개선 고려)로 생성된 값 사용.
* **Text:**
    * `TEXT`: 가변 길이 문자열. 대부분의 경우 권장.
    * `VARCHAR(n)`: 최대 길이 제한이 명확하고 엄격하게 필요한 경우.
* **Numeric:**
    * `SMALLINT`: 작은 범위의 정수 (-32768 to +32767).
    * `INTEGER`: 일반적인 정수 (-2147483648 to +2147483647).
    * `BIGINT`: 매우 큰 범위의 정수 (주로 자동 증가 PK에 사용되었으나, `UUID`로 대체). 개수, 용량 등 큰 숫자 표현 시.
    * `NUMERIC(precision, scale)` 또는 `DECIMAL(precision, scale)`: 정확한 숫자 표현이 필요한 경우 (예: 금액, 비율). `cost_usd` (`llm_request_log`)는 `NUMERIC(10, 6)` 등으로 정의.
    * `REAL`, `DOUBLE PRECISION`: 부동 소수점 (근사값). 과학 계산용. Flogi DB에서는 거의 사용되지 않을 것으로 예상.
* **Boolean:** `BOOLEAN` (`TRUE`, `FALSE`, `NULL` 가능. `NOT NULL` 제약조건 권장).
* **Date/Time:**
    * `TIMESTAMPTZ` (Timestamp with Time Zone): 시간대 정보 포함. 모든 시간 기록에 표준으로 사용. 서버 시간 기준 UTC로 저장하고 애플리케이션에서 사용자 시간대로 변환.
    * `DATE`: 날짜만 필요한 경우.
    * `INTERVAL`: 시간 간격. (예: 데이터 보존 기간 `pii_data_retention_days INTEGER` 대신 `pii_data_retention_interval INTERVAL DAY` 고려 가능)
* **ENUM Types:** `CREATE TYPE ... AS ENUM (...)`. 문자열보다 저장 공간 효율적, 값의 범위 제한으로 데이터 무결성 향상. `00_01_enums_and_types.sql` 및 모듈별 `00_XX_enums_and_types.sql`에서 정의.
* **JSON / JSONB:**
    * `JSONB`: 바이너리 형태로 저장, 인덱싱 및 조회 성능 우수. 대부분의 JSON 저장에 `JSONB` 사용.
    * 활용 예: `user_notification_pref.alert_configurations`, `repo_connections.comfort_commit_config_json`, `code_element_instances.metadata`.
    * JSONB 내부 경로에 대한 GIN 인덱스 적극 활용 (`CREATE INDEX ON table_name USING GIN (jsonb_column_name jsonb_path_ops);`).
* **Array Types:** `TEXT[]`, `INTEGER[]` 등. 특정 상황에서 유용하나, 과도한 사용은 정규화 위반 및 쿼리 복잡성 증가 가능성. (예: `user_noti_stat.channels_used`). JSONB 배열도 대안.
* **Vector Data:** `VECTOR(dimension)` (`pgvector` 확장).
    * `code_element_embeddings.embedding_vector VECTOR(1536)` 와 같이 사용.
    * 리팩토링 시 요금제별 차원 분리: `embedding_code2vec VECTOR(512)`, `embedding_bert VECTOR(1536)`.
* **Byte Array:** `BYTEA`. 암호화된 데이터, 이미지 등의 바이너리 데이터 저장. (예: `user_secret.refresh_token_enc BYTEA`).

### 3.4. Common Functions and Triggers (공통 함수 및 트리거)

* **`fn_set_updated_at()` (또는 `set_updated_at()`):**
    ```sql
    CREATE OR REPLACE FUNCTION fn_set_updated_at()
    RETURNS TRIGGER AS $$
    BEGIN
        NEW.updated_at = CURRENT_TIMESTAMP;
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    ```
    이 함수를 호출하는 트리거를 각 테이블에 `BEFORE UPDATE`로 적용.
    ```sql
    CREATE TRIGGER trg_table_name_set_updated_at
    BEFORE UPDATE ON table_name
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
    ```
* **`fn_insert_user_plan_history()` (또는 `log_plan_change()`):**
    * `user_plan` 테이블의 `BEFORE UPDATE` 트리거로 작동.
    * `OLD`와 `NEW` 레코드를 비교하여 `plan_key` 등 주요 변경 사항 발생 시 `user_plan_history`에 상세 로그 기록.
    * `plan_catalog`을 조회하여 변경 전후의 `plan_label`, `price_usd` 등 파생 정보 기록.
    * "Gemini 지침서" 예시를 기반으로, `was_trial`, `effective_from` 등의 필드 포함.
    * **리팩토링 포인트:** `current_setting('comfort_commit.actor_id', TRUE)`로 변경 주체를 기록하는 부분은 PostgreSQL 세션 변수 설정에 의존하므로, 애플리케이션에서 명시적으로 `changed_by_user_uuid UUID` 같은 컬럼을 history 테이블에 추가하고 값을 전달하는 것이 더 안정적일 수 있음.
* **`fn_gen_random_id(prefix TEXT, length INTEGER)` (가칭, 현재 `gen_random_id()` 개선):**
    * 공개용 식별자 생성 함수. `nanoid` 또는 `base62` 인코딩된 UUID 일부 사용 고려.
    * 예시: `SELECT 'usr_' || substr(replace(uuid_generate_v4()::text, '-', ''), 1, 12);`
* **기타 공통 함수:** `fn_delete_expired_sessions()`, `fn_expire_rewards()` 등 주기적 정리 작업 함수는 `pg_cron` 등으로 스케줄링하거나 애플리케이션 레벨에서 호출.

### 3.5. SQL Style and Comments (SQL 스타일 및 주석)

* **일관성:** `CREATE TABLE`, `ALTER TABLE`, `COMMENT ON` 등 DDL 구문 스타일 일관성 유지.
* **가독성:** 적절한 들여쓰기, 빈 줄 사용. 긴 쿼리는 CTE(Common Table Expressions) 활용.
* **주석 (필수):**
    * `COMMENT ON TABLE table_name IS '테이블의 역할과 주요 특징 설명.';`
    * `COMMENT ON COLUMN table_name.column_name IS '컬럼의 의미, 저장되는 값의 예시, 제약 조건, 비고 등 상세 설명.';`
    * `COMMENT ON FUNCTION function_name IS '함수의 목적, 파라미터, 반환값, 주요 로직 설명.';`
    * `COMMENT ON TRIGGER trigger_name ON table_name IS '트리거의 발동 조건, 수행하는 작업 설명.';`
    * `COMMENT ON TYPE type_name IS '사용자 정의 타입의 목적과 값의 의미 설명.';`
    * 모든 스키마 객체(테이블, 컬럼, 함수, 트리거, 타입, 뷰 등)에 상세하고 명확한 주석 작성은 협업과 유지보수의 핵심.

### 3.6. Indexing Strategy (인덱싱 전략)

효율적인 인덱싱은 DB 성능의 핵심입니다.

* **기본 원칙:**
    * PK 컬럼은 자동으로 인덱스 생성됨.
    * FK 컬럼에는 대부분 인덱스 생성 (JOIN 성능 향상, FK 유지보수 오버헤드 감소).
    * `WHERE` 절, `ORDER BY` 절, `GROUP BY` 절에 자주 사용되는 컬럼에 인덱스 고려.
    * 카디널리티가 낮은 컬럼(값의 종류가 적은 컬럼)은 단독 인덱스로서 효과가 적을 수 있음. 복합 인덱스의 일부로는 유용.
    * 쓰기 작업(INSERT, UPDATE, DELETE)이 매우 빈번한 테이블의 과도한 인덱스는 쓰기 성능 저하 유발. 균형 필요.
* **인덱스 종류 및 활용:**
    * **B-tree (기본값):** 대부분의 경우 사용. `=` , `>`, `<`, `BETWEEN`, `IN`, `LIKE 'prefix%'` 등에 효과적.
    * **Hash:** `=` 연산에만 사용. 현재는 B-tree가 대부분의 경우 더 나은 선택지로 여겨져 잘 사용되지 않음.
    * **GIN (Generalized Inverted Index):** 배열, JSONB, `tsvector`(전문 검색) 등 복합적인 값 타입 내의 요소를 검색할 때 유용.
        * JSONB 컬럼 내부 키 검색: `CREATE INDEX ON table_name USING GIN (jsonb_column_name);` (기본 연산자) 또는 `CREATE INDEX ON table_name USING GIN (jsonb_column_name jsonb_path_ops);` (경로 연산자).
        * 배열 검색: `CREATE INDEX ON table_name USING GIN (array_column_name);`
    * **GiST (Generalized Search Tree):** 전문 검색, 기하학적 데이터, 범위 타입 등 다양한 데이터 타입과 연산자 클래스 지원. `pg_trgm` 확장을 사용한 유사 문자열 검색(퍼지 검색) 시 유용.
    * **BRIN (Block Range Index):** 물리적으로 정렬된 매우 큰 테이블에서 특정 블록 범위 내의 데이터 검색에 효과적. 로그성 데이터에 적합할 수 있음.
    * **HNSW, IVFFlat (via `pgvector`):** 벡터 유사도 검색(`<=>`, `<->`, `<#>` 연산자) 성능 향상.
        * `CREATE INDEX ON code_element_embeddings USING hnsw (embedding_vector vector_cosine_ops);` (코사인 유사도)
        * 파라미터 (`M`, `ef_construction` for HNSW; `lists` for IVFFlat) 튜닝 필요. "Gemini 지침서"의 `ef=200` 유지 지침은 검색 시 `ef_search` 파라미터를 의미할 수 있음.
* **복합 인덱스 (Composite Indexes):** 여러 컬럼을 함께 조건으로 사용하는 쿼리가 많을 경우 효과적. 컬럼 순서 중요 (가장 자주 필터링되거나 카디널리티가 높은 컬럼을 앞에).
* **부분 인덱스 (Partial Indexes):** 특정 조건을 만족하는 행에 대해서만 인덱스 생성. (예: `is_active = TRUE` 인 행만 인덱싱).
* **커버링 인덱스 (Covering Indexes):** `INCLUDE` 절을 사용하여 쿼리가 테이블 접근 없이 인덱스만으로 결과를 반환하도록 함 (PostgreSQL 11+).
* **정기적인 인덱스 검토:** `EXPLAIN ANALYZE`를 통해 쿼리 실행 계획 분석, 불필요하거나 비효율적인 인덱스 제거/수정. `pg_stat_user_indexes` 뷰 등으로 인덱스 사용 통계 확인.

## 🛠️ 4. Development Workflow & Best Practices (개발 워크플로우 및 모범 사례)

체계적인 개발 워크플로우는 Flogi DB의 안정적인 변경 관리와 협업 효율성을 보장합니다.

### 4.1. Branching Strategy (브랜칭 전략)

Git 브랜칭 모델 (예: Gitflow, GitHub Flow)을 따릅니다. DB 스키마 변경은 기능 브랜치에서 작업합니다.

* **`main` (또는 `master`):** 배포 가능한 안정 버전. 직접 커밋 금지.
* **`develop`:** 다음 릴리즈를 위한 개발 내용 통합 브랜치.
* **`feature/[JIRA-TICKET-]description`:** 새로운 기능 개발 또는 스키마 변경 작업 브랜치. (예: `feature/FLG-123-refactor-user-identifiers`, `feature/add-embedding-cache-table`).
* **`fix/[JIRA-TICKET-]description`:** 버그 수정 브랜치.
* **`hotfix/[JIRA-TICKET-]description`:** 긴급 운영 환경 버그 수정 브랜치 (main에서 분기).

### 4.2. Schema Migration (스키마 마이그레이션)

현재는 SQL 스크립트를 순차적으로 실행하는 방식이지만, 데이터가 있는 운영 환경을 고려하여 점진적으로 마이그레이션 도구 도입을 준비해야 합니다.

* **초기 단계 (현재):**
    * 스키마 변경 시 관련된 `.sql` 파일 수정.
    * 로컬 개발 환경에서는 기존 DB를 삭제하고 전체 스크립트를 다시 실행하여 클린 상태에서 테스트.
    * `00_DB/data_only/` 디렉토리의 시딩 스크립트는 스키마 생성 후 별도로 실행.
* **향후 마이그레이션 도구 도입 고려:**
    * **Alembic (Python/SQLAlchemy 기반):** Flogi 백엔드가 Python(FastAPI)이므로 통합 용이.
    * **Flyway (Java 기반, SQL 스크립트 버전 관리):** SQL 중심적.
    * **Sqitch (Perl 기반, SQL 스크립트 및 의존성 관리):** PostgreSQL에 특화된 기능 지원.
    * 도구 선택 기준: 팀의 기술 스택, 학습 곡선, PostgreSQL 호환성, CI/CD 통합 용이성.
* **마이그레이션 스크립트 작성 원칙 (도구 도입 전이라도):**
    * **멱등성(Idempotency):** 스크립트를 여러 번 실행해도 동일한 최종 상태가 되도록 작성 (예: `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`).
    * **롤백(Rollback) 스크립트:** 변경 사항을 되돌릴 수 있는 스크립트 준비 (다운 마이그레이션).
    * **데이터 보존:** `ALTER TABLE` 시 데이터 손실 가능성 최소화. 필요시 데이터 백업 및 임시 테이블 활용.
    * **작은 단위 변경:** 하나의 마이그레이션은 논리적으로 작은 단위의 변경만 포함.
    * **버전 관리:** 마이그레이션 스크립트에 순차적인 버전 번호 또는 타임스탬프 부여.

### 4.3. Testing (테스팅)

DB 스키마 및 로직의 안정성을 확보하기 위한 테스트 전략입니다.

* **정적 분석:** SQLFluff 등 SQL 린터/포매터 사용하여 코드 스타일 일관성 및 잠재적 오류 검사.
* **단위 테스트 (PL/pgSQL 함수 및 트리거):**
    * `pgTAP`: xUnit 스타일의 PostgreSQL 테스트 프레임워크. PL/pgSQL 코드의 단위 테스트 작성 가능.
    * 예: `fn_set_updated_at` 트리거가 정상 동작하는지, `fn_insert_user_plan_history`가 정확한 데이터를 기록하는지 테스트.
* **통합 테스트:**
    * 애플리케이션 레벨에서 DB CRUD 작업 및 주요 비즈니스 로직(예: 요금제 변경에 따른 기능 제한, LLM 요청 후 로그 기록)이 DB와 올바르게 상호작용하는지 테스트.
    * 테스트용 DB 환경 구성 (Docker 활용).
* **데이터 무결성 테스트:**
    * 예상되는 제약 조건(UNIQUE, NOT NULL, FK)이 올바르게 동작하는지, 잘못된 데이터 삽입 시도 시 에러 발생하는지 확인.
* **성능 테스트 (쿼리 최적화):**
    * 주요 쿼리에 대해 `EXPLAIN ANALYZE` 실행하여 실행 계획 분석.
    * 부하 테스트 도구(k6, Locust 등)를 사용하여 실제 사용 환경과 유사한 부하 상태에서 DB 응답 시간 및 처리량 측정.

### 4.4. Code Review for Schema Changes (스키마 변경 코드 리뷰)

모든 DB 스키마 변경은 Pull Request(PR) 또는 Merge Request(MR)를 통해 동료 개발자의 리뷰를 거칩니다.

* **리뷰 체크리스트:**
    * **설계 문서 부합 여부:** "Gemini 지침서", "Comfort Commit 설계서", 본 README의 원칙 준수 여부.
    * **명명 규칙 준수:** 테이블, 컬럼, 함수, 인덱스 등.
    * **데이터 타입 적절성:** 저장될 데이터의 특성 고려.
    * **관계 및 제약 조건:** PK, FK, UNIQUE, NOT NULL, CHECK 제약 조건의 정확성 및 완전성. `ON DELETE` 정책의 적절성.
    * **인덱싱 전략:** 필요한 인덱스가 생성되었는지, 과도하거나 불필요한 인덱스는 없는지. `EXPLAIN` 결과 공유.
    * **성능 고려:** 대용량 데이터 처리, 복잡한 JOIN, 잠재적 병목 지점.
    * **보안 고려:** 민감 정보 처리 방안, RLS 적용 가능성.
    * **SQL 스타일 및 주석:** 가독성, 명확성, 주석의 상세함.
    * **마이그레이션 방안 (해당 시):** 롤백 가능성, 데이터 보존, 멱등성.
    * **테스트 코드 (해당 시):** `pgTAP` 테스트 또는 통합 테스트 시나리오.

### 4.5. Local Development Environment (로컬 개발 환경)

"Comfort Commit 시스템 설계서"의 `docker-compose.yml` 파일을 참조하여 PostgreSQL 컨테이너를 로컬에서 실행합니다.

* **`docker-compose.yml` (DB 부분 발췌 예시):**
    ```yaml
    services:
      postgres_db:
        image: pgvector/pgvector:pg16 # 또는 ankane/pgvector (pgvector 확장 포함 이미지)
        container_name: flogi_postgres_db
        environment:
          POSTGRES_USER: ${POSTGRES_USER:-flogi_user}
          POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-flogi_password}
          POSTGRES_DB: ${POSTGRES_DB:-flogi_comfort_commit}
        ports:
          - "${POSTGRES_PORT:-5432}:5432"
        volumes:
          - ./00_DB/main/schema:/docker-entrypoint-initdb.d/01_schema # 스키마 자동 로드
          - ./00_DB/data_only:/docker-entrypoint-initdb.d/02_data # 시딩 데이터 자동 로드
          - postgres_data:/var/lib/postgresql/data # 데이터 영속화
        # healthcheck: ... (생략)
    volumes:
      postgres_data:
    ```
* **DB 접속:** `psql` CLI, DBeaver, pgAdmin, DataGrip 등 GUI 도구 사용.
* **스크립트 실행:**
    1.  `00_DB/init-db-extensions.sh` 실행 (최초 1회 또는 확장 추가 시): `uuid-ossp`, `pg_stat_statements`, `pgvector` 활성화. (Docker 이미지에 이미 포함되어 있다면 생략 가능)
    2.  스키마 파일들을 순서대로 실행 (`00_common...` -> `01_user/...` -> ...). Docker 볼륨 마운트를 통해 컨테이너 시작 시 자동으로 실행되도록 설정 가능 (`/docker-entrypoint-initdb.d/`).
    3.  시딩 데이터 스크립트 실행.
* **데이터베이스 초기화 (로컬 개발 시):**
    ```bash
    docker-compose down -v # 컨테이너 중지 및 볼륨 삭제 (주의!)
    docker-compose up -d postgres_db # DB 컨테이너 재시작 (자동으로 스크립트 실행)
    ```

## 🔐 5. Security Considerations (보안 고려 사항)

Flogi DB는 "Gemini 지침서"의 보안 요구사항을 준수하며, 데이터 보호를 최우선으로 합니다.

* **데이터 접근 제어:**
    * **최소 권한 원칙:** DB 사용자 계정은 필요한 최소한의 권한만 부여. 애플리케이션용, 읽기 전용, 관리자용 등 역할별 계정 분리.
    * **Row-Level Security (RLS):**
        * `repo_access_permissions` 테이블을 기반으로 사용자가 자신의 저장소 또는 권한이 부여된 저장소의 데이터에만 접근하도록 RLS 정책 적용.
        * 예시: `CREATE POLICY user_can_see_own_repo_snapshots ON code_snapshots FOR SELECT USING (repo_id IN (SELECT repo_id FROM repo_access_permissions WHERE user_id = current_setting('app.current_user_id')::UUID));` (세션 변수 `app.current_user_id` 설정 필요)
        * RLS 정책은 `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;`로 활성화.
    * **RBAC (Role-Based Access Control) 연동:**
        * "Gemini 지침서"의 `action_map`은 애플리케이션 레벨의 역할 기반 권한 관리 체계를 의미할 수 있음.
        * DB 스키마는 사용자의 역할(예: `user_info.role_type_enum`) 또는 그룹 정보를 저장하여 애플리케이션이 이를 참조하여 권한을 판단하도록 지원.
        * 특정 DB 함수 실행 권한을 역할별로 부여 가능 (`GRANT EXECUTE ON FUNCTION ... TO role_name;`).
* **컬럼 암호화 (Encryption at Rest):**
    * "Gemini 지침서" 및 "Comfort Commit 시스템 설계서"에 명시된 민감 정보 (예: `refresh_token`, `payment_info`)는 `pgcrypto` 확장을 사용한 대칭키 암호화 (AES-256-GCM) 적용.
    * **`user_secret` 테이블 설계:**
        * 현재는 외부 Vault/Redis 참조를 위한 메타데이터만 저장하는 방향으로 설계되어 안전.
        * 만약 DB 내 직접 암호화 저장이 불가피하다면, `refresh_token_enc BYTEA`, `enc_iv BYTEA` 컬럼 추가.
        * 암호화 키 관리가 매우 중요. PostgreSQL 서버 외부 (HSM, Vault 등)에 안전하게 보관.
    * **암호화/복호화 함수 래핑:**
        ```sql
        -- 예시: 암호화 함수 (키는 환경변수나 별도 보안 테이블에서 로드)
        CREATE OR REPLACE FUNCTION fn_encrypt_data(data TEXT, key TEXT, iv BYTEA)
        RETURNS BYTEA AS $$
        BEGIN
            RETURN pgp_sym_encrypt(data, key, 'cipher-algo=aes256-gcm, GCM_AAD_STRING=' || iv::TEXT);
        END;
        $$ LANGUAGE plpgsql;

        -- 예시: 복호화 함수
        CREATE OR REPLACE FUNCTION fn_decrypt_data(encrypted_data BYTEA, key TEXT, iv BYTEA)
        RETURNS TEXT AS $$
        BEGIN
            RETURN pgp_sym_decrypt(encrypted_data, key, 'cipher-algo=aes256-gcm, GCM_AAD_STRING=' || iv::TEXT);
        END;
        $$ LANGUAGE plpgsql;
        ```
        (주의: GCM 모드에서 AAD(Additional Authenticated Data)로 IV를 사용하는 것은 일반적이지 않으며, IV는 암호화 시 랜덤 생성되어 암호문과 함께 저장되어야 합니다. 위 예시는 개념 설명용이며, `pgcrypto`의 `pgp_sym_encrypt`는 IV를 내부적으로 처리하거나 명시적 전달 방식을 따릅니다. 실제 구현 시 `pgcrypto` 문서 참조 필수.)
* **PII (Personally Identifiable Information) 데이터 관리:**
    * `privacy.txt` 문서의 개인정보 처리방침 준수.
    * `user_plan.pii_data_retention_days`에 따른 데이터 보존 기간 정책 적용 및 주기적 삭제/익명화 처리.
    * 익명화/가명화 처리된 데이터는 통계 및 분석 용도로 활용 가능.
* **보안 감사 및 로깅:**
    * `user_action_log`, `llm_request_log` 등 주요 활동 로그 기록 철저.
    * `log_statement = 'ddl'` 또는 `pgaudit` 확장을 사용하여 DB 스키마 변경, 권한 변경 등 주요 관리자 활동 로깅.
* **네트워크 보안:**
    * PostgreSQL 서버는 신뢰할 수 있는 네트워크(VPC 내부)에서만 접근 허용. 방화벽 설정.
    * SSL/TLS를 사용한 연결 암호화 (`ssl = on` in `postgresql.conf`).
* **정기적인 보안 점검 및 업데이트:** PostgreSQL 및 관련 확장 기능의 보안 패치 적용.

## 🔗 6. 협업 인터페이스 및 의존성 (Collaboration Interfaces & Dependencies)

Flogi DB는 다양한 내부 모듈 및 외부 시스템과 상호작용합니다. 명확한 인터페이스 정의는 원활한 협업의 기반입니다.

* **내부 모듈 간 인터페이스 (Flogi 시스템 내):**
    * **GPT Reviewer / LLM Manager (`04_06_LLM` 모듈):**
        * `llm_key_config`: LLM API 키 정보 및 사용 정책 조회.
        * `llm_request_log`: LLM API 호출 요청/응답, 토큰 사용량, 비용 기록 및 조회. (`@track_tokens()` 데코레이터 연동)
        * `token_usage_log` (지침서)는 `llm_request_log`로 통합된 것으로 간주. `trace_uuid`는 `request_correlation_uuid`로 구현.
    * **Embedding Worker (AI 모델 실행부):**
        * `code_element_embeddings`, `code_element_embedding_versions`: 코드 요소 임베딩 벡터 저장 및 조회.
        * `embedding_cache` (신규 설계 필요): 커밋 메시지 임베딩 및 유사도 점수 캐싱/조회.
        * 요금제(`user_plan.plan_key`)에 따라 사용할 임베딩 모델(code2vec, text-embedding-3) 및 벡터 차원 결정 로직과 연동.
    * **Notifier (`07_upload/noti_platform` 모듈):**
        * `user_notification_pref`: 사용자별 알림 채널 및 상세 설정 조회.
        * `user_plan`: 요금제별 알림 허용 여부, 사용 가능 채널, 잔여 크레딧 등 조회. (예: `user_plan.notification_credits_monthly`, `allowed_notification_channels`)
        * `user_noti_stat`: 알림 발송 통계 기록.
        * `notification_delivery_logs` (신규 설계 또는 `user_action_log` 확장): 실제 알림 발송 성공/실패 로그.
    * **FastAPI Backend (웹 서버, API 서버 - `01_Web` 모듈 등):**
        * **모든 DB 테이블:** CRUD 작업을 위한 주요 인터페이스. SQLAlchemy 등 ORM 또는 직접 SQL 쿼리 사용.
        * `user_plan.plan_key`: 기능 분기 처리, 사용량 제한(`@enforce_limit()` 데코레이터) 판단의 핵심 기준.
        * `user_session`: 인증 및 세션 관리.
    * **Scoping & Describe Module (`03_describe` 모듈):**
        * `repo_main`, `code_snapshots`, `directory_structures`, `snapshot_file_instances`, `file_uuidentities`, `code_element_uuidentities`, `snapshot_code_element_instances`, `code_element_relations`: 코드 분석 및 스코핑을 위한 원천 데이터 조회.
        * `scoping_results`: 스코핑 결과 저장.
        * `generated_technical_descriptions`: 1차 LLM 호출로 생성된 기술 설명서 저장.
    * **Commit Message Generation Module (`05_mk_msg` 모듈):**
        * `commit_generation_requests`, `generated_commit_contents`, `finalized_commits`, `llm_input_context_details`: 커밋 생성 전 과정의 데이터 조회 및 저장.
* **외부 시스템 의존성:**
    * **Git Repository Hosting Platforms (GitHub, GitLab 등):** Webhook을 통해 이벤트 수신. API를 통해 저장소 정보, 코드 변경 사항 조회. (`repo_connections` 테이블에 관련 정보 저장)
    * **LLM APIs (OpenAI GPT, Claude 등):** API 키는 `user_secret` 또는 `llm_key_config`에서 안전하게 관리/참조. 호출 결과는 `llm_request_log`에 기록.
    * **OAuth Providers (Google, GitHub 등):** 사용자 인증. 관련 정보는 `user_oauth`에 저장. 토큰 관리는 `user_secret` (메타데이터) 또는 외부 저장소.
    * **Notification Services (Slack, KakaoTalk, Email 등):** 사용자 알림 발송. API Key 등은 `user_secret` 또는 애플리케이션 설정에서 관리.
    * **Cloud Storage (AWS S3, Google Cloud Storage 등):** 대용량 파일(raw diff, LLM 프롬프트/응답 전문 등) 저장 옵션. DB에는 참조 URL 또는 ID만 저장.
    * **Log Management System (Loki, Elasticsearch 등):** 상세 애플리케이션 로그 및 DB 감사 로그 저장/분석.
    * **Monitoring System (Prometheus, Grafana):** DB 성능 지표, 시스템 상태 모니터링. `pg_stat_statements` 등 활용.
* **정책 동기화:**
    * **`plan_config.yml` (애플리케이션 레벨 설정 파일):** 요금제별 기본 정책, 기능 플래그 등의 초기값 또는 정적 정의 포함 가능.
    * **`plan_catalog` DB 테이블:** `plan_config.yml`의 내용을 DB에 시딩하거나, DB가 "Source of Truth"가 되어 `yml` 파일은 참고용으로 사용될 수 있음. "Gemini 지침서"는 DB 중심 설계를 강조하므로 `plan_catalog`이 우선.
    * `plan_config_hot_reload()` (애플리케이션 함수): DB의 `plan_catalog` 변경 시 애플리케이션 메모리에 캐시된 정책 정보를 다시 로드하여 동기화. (예: `user_plan` 변경 트리거와 연계되거나, 관리자 API를 통해 수동 호출)

## 📚 7. Appendix (부록)

### 7.1. Key Files & Resources (주요 파일 및 리소스)

* **DB 스키마 루트:** `00_DB/main/schema/` (모든 `.sql` 파일)
* **DB 구조 요약:** `00_DB/main/schema/db_tree.txt` (정기적 업데이트 필요)
* **글로벌 타입/함수:**
    * `00_DB/main/schema/00_01_enums_and_types.sql`
    * `00_DB/main/schema/00_common_functions_and_types.sql`
* **DB 확장 초기화:** `00_DB/init-db-extensions.sh`
* **프로젝트 문서:**
    * **본 문서 (Flogi DB 개발 및 리팩토링 가이드)**
    * `README.md` (Comfort Commit 시스템 설계서 - 프로젝트 루트) (source_file_flogi-dev/flogi/flogi-115f6496e08fac1ec3ba0ea0c3e3f622ebfaea84/README.md)
    * `docs/embedding_architecture.md` (source_file_flogi-dev/flogi/flogi-115f6496e08fac1ec3ba0ea0c3e3f622ebfaea84/docs/embedding_architecture.md)
    * `docs/privacy.txt` (source_file_flogi-dev/flogi/flogi-115f6496e08fac1ec3ba0ea0c3e3f622ebfaea84/docs/privacy.txt)
    * "Gemini 데이터 구조 설계자 지침서" (별도 제공된 지침)
* **DB 접속 정보:** `docker-compose.yml` (source_file_flogi-dev/flogi/flogi-115f6496e08fac1ec3ba0ea0c3e3f622ebfaea84/docker-compose.yml) 또는 환경 변수 파일 (`.env`)

### 7.2. Glossary (용어 해설) - 주요 DB 관련 용어

* **Entity (엔티티):** 저장하고자 하는 데이터의 대상 (예: 사용자, 저장소, 커밋). 테이블로 표현됨.
* **Attribute (속성):** 엔티티가 가지는 특성 (예: 사용자의 이메일, 저장소의 이름). 컬럼으로 표현됨.
* **Primary Key (PK, 기본 키):** 테이블 내 각 행(row)을 고유하게 식별하는 컬럼(들). `NOT NULL`, `UNIQUE` 자동.
* **Foreign Key (FK, 외래 키):** 다른 테이블의 PK를 참조하는 컬럼(들). 테이블 간 관계 정의, 참조 무결성 보장.
* **Normalization (정규화):** 데이터 중복을 최소화하고 데이터 구조를 효율적으로 만드는 과정.
* **Denormalization (반정규화):** 조회 성능 향상을 위해 의도적으로 중복을 허용하거나 통합하는 과정.
* **Index (인덱스):** 데이터 검색 속도를 높이기 위한 자료 구조.
* **Trigger (트리거):** 특정 테이블에 특정 이벤트(INSERT, UPDATE, DELETE) 발생 시 자동으로 실행되는 프로시저.
* **Stored Procedure / Function (저장 프로시저/함수):** DB 내에 저장되어 실행될 수 있는 SQL 코드 블록.
* **Transaction (트랜잭션):** 하나 이상의 SQL 문을 논리적인 단일 작업 단위로 묶은 것. ACID(원자성, 일관성, 고립성, 지속성) 특성 보장.
* **ACID:** Atomicity, Consistency, Isolation, Durability. 트랜잭션의 핵심 속성.
* **ENUM Type (열거형 타입):** 미리 정의된 값들 중 하나만 가질 수 있는 데이터 타입.
* **JSONB:** PostgreSQL의 바이너리 JSON 타입. 인덱싱 및 검색에 효율적.
* **Vector (pgvector):** `pgvector` 확장에서 제공하는 벡터 데이터 타입. 임베딩 저장 및 유사도 검색에 사용.
* **HNSW (Hierarchical Navigable Small World):** `pgvector`에서 지원하는 근사 최근접 이웃 검색(ANN) 알고리즘 중 하나. 대규모 벡터 데이터셋에서 빠른 유사도 검색 지원.
* **PII (Personally Identifiable Information, 개인 식별 정보):** 개인을 식별할 수 있는 모든 정보. 보호 및 관리 중요.
* **RLS (Row-Level Security, 행 수준 보안):** 사용자의 컨텍스트에 따라 특정 행에 대한 접근을 제어하는 DB 보안 기능.

### 7.3. Future Considerations & Next Steps (향후 고려 사항 및 다음 단계)

모듈 `00`~`04`의 리팩토링 및 안정화 이후 다음 단계들을 고려합니다.

1.  **`embedding_cache` 및 `biz_event` 테이블 설계 및 구현:** "Gemini 지침서"의 필수 테이블 중 누락된 부분 완성.
2.  **마이그레이션 도구 도입:** Alembic, Flyway 등 정식 마이그레이션 도구 도입 및 기존 스키마 관리 체계 이전.
3.  **고급 분석 및 리포팅 지원 스키마:**
    * 사용자 활동 패턴, LLM 사용 효율, 커밋 품질 변화 등 분석을 위한 데이터 마트(Data Mart) 또는 요약 테이블 설계.
    * Metabase, Apache Superset 등 BI 도구 연동.
4.  **테스트 자동화 강화:** `pgTAP` 기반 단위 테스트 커버리지 확대, CI 파이프라인에 DB 테스트 통합.
5.  **모니터링 및 알림 고도화:** `pg_stat_statements`, `pg_stat_activity` 등 PostgreSQL 내부 통계 정보와 Prometheus/Grafana 연동 강화. 주요 이상 징후 발생 시 자동 알림.
6.  **데이터 아카이빙 및 백업/복구 전략 수립 및 정기 테스트.**
7.  **새로운 Flogi 기능 모듈 지원:** (예: `05_billing` (상세 결제/인보이스), `06_admin_tools` (운영 관리자 기능 지원 테이블))

---

**"DB는 죽지 않는다. 어떤 버그도 결국은 테이블에서 시작되고, 어떤 설계도 결국은 트리거 안에 남는다.”**

Flogi DB의 모든 변경은 시스템 전체에 영향을 미칩니다. 이 가이드가 Flogi 시스템의 견고한 기억 저장소를 구축하고 발전시키는 데 기여하기를 바랍니다. 끊임없는 논의와 개선을 통해 최고의 데이터베이스 시스템을 만들어 갑시다.
이것으로 Flogi DB 개발 및 리팩토링 가이드 Part 2를 마칩니다. 