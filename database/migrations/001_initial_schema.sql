-- PostgreSQL 15+
-- Initial schema only; no authentication, payment custody, or production authorization.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_hash text UNIQUE,
  phone_encrypted text,
  display_name varchar(40),
  account_status text NOT NULL DEFAULT 'pending'
    CHECK (account_status IN ('pending','active','suspended','closed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_name varchar(160) NOT NULL,
  registration_number_encrypted text,
  registration_number_hash text UNIQUE,
  contact_name varchar(60),
  contact_phone_encrypted text,
  verification_status text NOT NULL DEFAULT 'pending'
    CHECK (verification_status IN ('pending','verified','rejected','suspended')),
  verification_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE organization_members (
  organization_id uuid NOT NULL REFERENCES organizations(id),
  user_id uuid NOT NULL REFERENCES users(id),
  member_role text NOT NULL CHECK (member_role IN ('owner','operator','finance','viewer')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,user_id)
);

CREATE TABLE worker_profiles (
  user_id uuid PRIMARY KEY REFERENCES users(id),
  introduction varchar(500),
  skills jsonb NOT NULL DEFAULT '[]'::jsonb,
  service_regions jsonb NOT NULL DEFAULT '[]'::jsonb,
  accessibility_preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
  profile_status text NOT NULL DEFAULT 'draft'
    CHECK (profile_status IN ('draft','active','restricted')),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE demand_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_user_id uuid REFERENCES users(id),
  requester_organization_id uuid REFERENCES organizations(id),
  title varchar(100) NOT NULL,
  category varchar(40) NOT NULL,
  description text NOT NULL,
  worker_budget_cents bigint NOT NULL CHECK (worker_budget_cents > 0),
  platform_fee_cents bigint CHECK (platform_fee_cents >= 0),
  requester_total_cents bigint CHECK (requester_total_cents >= 0),
  currency char(3) NOT NULL DEFAULT 'CNY',
  desired_deadline timestamptz,
  status text NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('draft','pending_review','needs_more_info','pending_pricing','pending_authorization','approved','published','rejected','paused','cancelled','converted')),
  review_reason text,
  reviewed_by uuid REFERENCES users(id),
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(requester_user_id,requester_organization_id) = 1)
);
CREATE INDEX demand_requests_status_created_idx ON demand_requests(status,created_at DESC);

CREATE TABLE projects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_code varchar(32) NOT NULL UNIQUE,
  source_type text NOT NULL CHECK (source_type IN ('platform_managed','marketplace')),
  organization_id uuid REFERENCES organizations(id),
  demand_request_id uuid UNIQUE REFERENCES demand_requests(id),
  title varchar(120) NOT NULL,
  scope text NOT NULL,
  acceptance_criteria text NOT NULL,
  customer_revenue_cents bigint NOT NULL CHECK (customer_revenue_cents >= 0),
  worker_budget_cents bigint NOT NULL CHECK (worker_budget_cents >= 0),
  other_cost_budget_cents bigint NOT NULL DEFAULT 0 CHECK (other_cost_budget_cents >= 0),
  currency char(3) NOT NULL DEFAULT 'CNY',
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','awaiting_customer_confirmation','confirmed','recruiting','in_progress','quality_check','delivered','completed','disputed','cancelled','refunded')),
  owner_user_id uuid REFERENCES users(id),
  due_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((source_type = 'platform_managed' AND organization_id IS NOT NULL) OR source_type = 'marketplace')
);

CREATE TABLE project_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
  task_code varchar(40) NOT NULL UNIQUE,
  title varchar(120) NOT NULL,
  instructions text NOT NULL,
  deliverable_spec jsonb NOT NULL DEFAULT '{}'::jsonb,
  acceptance_checklist jsonb NOT NULL DEFAULT '[]'::jsonb,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_label varchar(24) NOT NULL DEFAULT '份',
  worker_pay_cents bigint NOT NULL CHECK (worker_pay_cents >= 0),
  estimated_minutes integer CHECK (estimated_minutes IS NULL OR estimated_minutes > 0),
  required_skills jsonb NOT NULL DEFAULT '[]'::jsonb,
  max_revision_rounds smallint NOT NULL DEFAULT 1 CHECK (max_revision_rounds BETWEEN 0 AND 5),
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','ready','recruiting','assigned','in_progress','submitted','under_review','revision_required','accepted','settlement_pending','settled','disputed','cancelled')),
  due_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX project_tasks_project_status_idx ON project_tasks(project_id,status);

CREATE TABLE task_dependencies (
  task_id uuid NOT NULL REFERENCES project_tasks(id) ON DELETE CASCADE,
  depends_on_task_id uuid NOT NULL REFERENCES project_tasks(id) ON DELETE RESTRICT,
  PRIMARY KEY (task_id,depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);

CREATE TABLE task_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES project_tasks(id) ON DELETE RESTRICT,
  worker_user_id uuid NOT NULL REFERENCES users(id),
  assigned_by uuid REFERENCES users(id),
  agreed_pay_cents bigint NOT NULL CHECK (agreed_pay_cents >= 0),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','withdrawn','submitted','accepted','rejected','cancelled')),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  UNIQUE (task_id,worker_user_id)
);
CREATE INDEX task_assignments_worker_status_idx ON task_assignments(worker_user_id,status);

CREATE TABLE file_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid REFERENCES users(id),
  organization_id uuid REFERENCES organizations(id),
  storage_key text NOT NULL UNIQUE,
  original_filename varchar(255),
  mime_type varchar(120) NOT NULL,
  byte_size bigint NOT NULL CHECK (byte_size >= 0),
  checksum_sha256 char(64),
  purpose text NOT NULL CHECK (purpose IN ('task_reference','task_submission','identity_verification','authorization_proof','contract','other')),
  access_scope text NOT NULL DEFAULT 'restricted'
    CHECK (access_scope IN ('restricted','project_members','private')),
  authorization_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  retention_until timestamptz,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (num_nonnulls(owner_user_id,organization_id) <= 1)
);

CREATE TABLE submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id uuid NOT NULL REFERENCES task_assignments(id) ON DELETE RESTRICT,
  version integer NOT NULL CHECK (version > 0),
  worker_note text,
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted','under_review','revision_required','accepted','rejected','withdrawn')),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (assignment_id,version)
);

CREATE TABLE submission_files (
  submission_id uuid NOT NULL REFERENCES submissions(id) ON DELETE CASCADE,
  file_asset_id uuid NOT NULL REFERENCES file_assets(id) ON DELETE RESTRICT,
  PRIMARY KEY (submission_id,file_asset_id)
);

CREATE TABLE reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id uuid NOT NULL REFERENCES submissions(id) ON DELETE RESTRICT,
  reviewer_user_id uuid REFERENCES users(id),
  decision text NOT NULL CHECK (decision IN ('accepted','revision_required','rejected')),
  reason text,
  checklist_results jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL UNIQUE REFERENCES projects(id) ON DELETE RESTRICT,
  payer_organization_id uuid REFERENCES organizations(id),
  gross_amount_cents bigint NOT NULL CHECK (gross_amount_cents >= 0),
  platform_fee_cents bigint NOT NULL DEFAULT 0 CHECK (platform_fee_cents >= 0),
  currency char(3) NOT NULL DEFAULT 'CNY',
  payment_provider text,
  provider_order_reference text UNIQUE,
  status text NOT NULL DEFAULT 'unpaid'
    CHECK (status IN ('unpaid','pending_payment','paid','partially_refunded','refunded','settlement_pending','settled','disputed','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE order_cost_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
  cost_type text NOT NULL CHECK (cost_type IN ('worker_pay','quality_check','rework','materials','logistics','payment_fee','refund_loss','other')),
  description varchar(240) NOT NULL,
  amount_cents bigint NOT NULL CHECK (amount_cents >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ledger_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES orders(id) ON DELETE RESTRICT,
  project_id uuid REFERENCES projects(id) ON DELETE RESTRICT,
  user_id uuid REFERENCES users(id),
  entry_type text NOT NULL CHECK (entry_type IN ('customer_receivable','customer_payment','worker_payable','worker_payout','platform_fee','refund','adjustment','payment_fee')),
  amount_cents bigint NOT NULL CHECK (amount_cents <> 0),
  currency char(3) NOT NULL DEFAULT 'CNY',
  idempotency_key varchar(100) NOT NULL UNIQUE,
  external_reference varchar(160),
  memo varchar(240),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ledger_entries_order_idx ON ledger_entries(order_id,created_at);
CREATE INDEX ledger_entries_user_idx ON ledger_entries(user_id,created_at DESC);

CREATE TABLE disputes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
  task_id uuid REFERENCES project_tasks(id) ON DELETE RESTRICT,
  raised_by uuid NOT NULL REFERENCES users(id),
  reason text NOT NULL,
  evidence jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','investigating','resolved_for_worker','resolved_for_requester','refunded','closed')),
  resolution text,
  handled_by uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

CREATE TABLE audit_logs (
  id bigserial PRIMARY KEY,
  actor_user_id uuid REFERENCES users(id),
  actor_role varchar(40) NOT NULL,
  action varchar(100) NOT NULL,
  entity_type varchar(60) NOT NULL,
  entity_id uuid,
  before_snapshot jsonb,
  after_snapshot jsonb,
  request_id varchar(80),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_entity_idx ON audit_logs(entity_type,entity_id,created_at DESC);

CREATE TABLE notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id),
  channel text NOT NULL CHECK (channel IN ('in_app','sms','email','push')),
  template_code varchar(80) NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued','sent','failed','cancelled')),
  attempts smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz
);

-- Production requirements not implemented by this DDL:
-- server-side authorization / row-level security; KMS encryption for PII;
-- transaction-safe double-entry accounting; provider reconciliation;
-- immutable audit retention; backups and restore drills;
-- file content scanning, signed URLs and expiry deletion;
-- a licensed payment provider for any customer funds.
