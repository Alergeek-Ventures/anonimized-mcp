-- Synthetic source database modelled on a typical AV Phoenix/Ash/Oban app.
-- Recreated from scratch by priv/sandbox/seed.exs.

DROP SCHEMA IF EXISTS public CASCADE;
DROP SCHEMA IF EXISTS oban CASCADE;
CREATE SCHEMA public;
CREATE SCHEMA oban;

CREATE TABLE organizations (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  nip text NOT NULL,
  address text,
  inserted_at timestamptz NOT NULL
);

CREATE TABLE users (
  id uuid PRIMARY KEY,
  organization_id uuid REFERENCES organizations (id),
  email text NOT NULL,
  name text,
  phone text,
  bank_account_number text,
  hashed_password text NOT NULL,
  inserted_at timestamptz NOT NULL
);

CREATE TABLE user_identities (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users (id),
  strategy text NOT NULL,
  access_token text,
  refresh_token text
);

CREATE TABLE counterparties (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  display_name text NOT NULL,
  given_name text,
  surname text,
  tax_id text,
  pesel text,
  email text,
  phone text,
  address text,
  description text
);

CREATE TABLE sales_invoices (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  buyer_id uuid REFERENCES counterparties (id),
  number text NOT NULL,
  state text NOT NULL,
  buyer_display_name text,
  buyer_tax_id text,
  gross_total numeric(12, 2) NOT NULL,
  currency text NOT NULL,
  issue_date date NOT NULL,
  internal_note text,
  ksef_number text
);

CREATE TABLE requisitions (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  status text NOT NULL,
  inserted_at timestamptz NOT NULL
);

CREATE TABLE bank_accounts (
  id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES organizations (id),
  requisition_id uuid REFERENCES requisitions (id),
  iban text NOT NULL,
  owner_name text,
  institution_name text NOT NULL
);

CREATE TABLE transactions (
  id uuid PRIMARY KEY,
  bank_account_id uuid NOT NULL REFERENCES bank_accounts (id),
  amount numeric(12, 2) NOT NULL,
  booking_date date NOT NULL,
  creditor_name text,
  creditor_account text,
  debtor_name text,
  debtor_account text,
  remittance_information_unstructured text
);

CREATE TABLE ash_events (
  id bigserial PRIMARY KEY,
  resource text NOT NULL,
  record_id uuid NOT NULL,
  action text NOT NULL,
  data jsonb NOT NULL,
  occurred_at timestamptz NOT NULL
);

CREATE TABLE oban.oban_jobs (
  id bigserial PRIMARY KEY,
  state text NOT NULL,
  queue text NOT NULL,
  worker text NOT NULL,
  args jsonb NOT NULL,
  meta jsonb NOT NULL DEFAULT '{}',
  errors jsonb[] NOT NULL DEFAULT '{}',
  attempt integer NOT NULL,
  max_attempts integer NOT NULL,
  inserted_at timestamptz NOT NULL,
  attempted_at timestamptz
);

GRANT USAGE ON SCHEMA public, oban TO debug_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public, oban TO debug_reader;
ALTER ROLE debug_reader SET default_transaction_read_only = on;
ALTER ROLE debug_reader SET statement_timeout = '15s';
ALTER ROLE debug_reader SET lock_timeout = '1s';
ALTER ROLE debug_reader SET idle_in_transaction_session_timeout = '5s';
