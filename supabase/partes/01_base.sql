-- =====================================================================
-- PARTE 1: TIPOS Y TABLAS BASE
-- =====================================================================
create schema if not exists app_private;
create extension if not exists pgcrypto with schema extensions;

do $$ begin
  create type public.app_role as enum ('admin','accountant','assistant','purchasing','auditor');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.doc_status as enum ('draft','pending_approval','rejected','approved','posted','voided');
exception when duplicate_object then null; end $$;

-- ---------- Catálogo compartido ----------
create table public.currencies (
  code char(3) primary key,
  name text not null,
  symbol text not null default ''
);
insert into public.currencies(code,name,symbol) values
 ('BOB','Boliviano','Bs'),('USD','Dólar estadounidense','$'),('EUR','Euro','€'),
 ('BRL','Real brasileño','R$'),('ARS','Peso argentino','$'),('CLP','Peso chileno','$'),
 ('PEN','Sol peruano','S/'),('PYG','Guaraní','₲'),('COP','Peso colombiano','$'),
 ('MXN','Peso mexicano','$'),('CNY','Yuan renminbi','¥'),('GBP','Libra esterlina','£')
on conflict do nothing;

-- ---------- Organización y usuarios ----------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  legal_name text not null,
  trade_name text,
  tax_id text,
  fiscal_address text,
  base_currency char(3) not null references public.currencies(code),
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  is_platform_admin boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);
create index on public.organization_members(user_id);

create table public.role_permissions (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  role public.app_role not null,
  permission text not null,
  primary key (organization_id, role, permission)
);

-- ---------- Configuración ----------
create table public.exchange_rates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  currency_code char(3) not null references public.currencies(code),
  rate_date date not null,
  rate numeric(18,8) not null check (rate > 0),
  source text,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  unique (organization_id, currency_code, rate_date)
);

create table public.accounting_periods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  start_date date not null,
  end_date date not null,
  status text not null default 'open' check (status in ('open','closed')),
  closed_at timestamptz,
  closed_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (end_date >= start_date),
  unique (organization_id, start_date)
);

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  parent_id uuid references public.accounts(id),
  account_type text not null check (account_type in ('asset','liability','equity','revenue','cost','expense')),
  nature text not null check (nature in ('debit','credit')),
  is_postable boolean not null default true,
  active boolean not null default true,
  description text,
  created_at timestamptz not null default now(),
  unique (organization_id, code)
);
create index on public.accounts(organization_id, parent_id);

create table public.activities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, code)
);

create table public.tax_types (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  rate numeric(9,4) not null check (rate >= 0 and rate <= 100),
  category text,
  applies_to text not null default 'both' check (applies_to in ('purchase','sales','both')),
  treatment text not null check (treatment in ('recoverable','cost','payable')),
  account_id uuid references public.accounts(id),
  valid_from date,
  valid_to date,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  unique (organization_id, code),
  check (treatment = 'cost' or account_id is not null or rate = 0)
);

create table public.accounting_rules (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  rule_key text not null,
  account_id uuid references public.accounts(id),
  primary key (organization_id, rule_key)
);

create table public.document_sequences (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_type text not null,
  prefix text not null default '',
  next_number bigint not null default 1,
  padding int not null default 5,
  primary key (organization_id, doc_type)
);

create table public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  kind text not null default 'bank_transfer' check (kind in ('cash','bank_transfer','check','card','other')),
  active boolean not null default true,
  unique (organization_id, name)
);

create table public.inventory_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  valuation_method text not null default 'weighted_average' check (valuation_method in ('weighted_average','fifo')),
  effective_from date not null default current_date,
  cost_decimals int not null default 4 check (cost_decimals between 2 and 6),
  allow_negative_stock boolean not null default false,
  updated_at timestamptz not null default now()
);

-- ---------- Terceros y productos ----------
create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  tax_id text,
  email text, phone text, address text,
  payment_terms_days int not null default 0,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index suppliers_tax_uk on public.suppliers(organization_id, tax_id) where tax_id is not null and tax_id <> '';

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  tax_id text,
  email text, phone text, address text,
  payment_terms_days int not null default 0,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index customers_tax_uk on public.customers(organization_id, tax_id) where tax_id is not null and tax_id <> '';

create table public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sku text not null,
  name text not null,
  product_type text not null default 'inventory' check (product_type in ('inventory','service')),
  unit text not null default 'unidad',
  category text,
  sale_price numeric(18,4) not null default 0,
  inventory_account_id uuid references public.accounts(id),
  revenue_account_id uuid references public.accounts(id),
  cogs_account_id uuid references public.accounts(id),
  expense_account_id uuid references public.accounts(id),
  qty_on_hand numeric(18,4) not null default 0,
  inventory_value numeric(18,2) not null default 0,
  avg_cost numeric(18,6) not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, sku)
);

create table public.cash_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  kind text not null default 'bank' check (kind in ('cash','bank')),
  bank_name text,
  account_number text,
  currency_code char(3) not null references public.currencies(code),
  account_id uuid not null references public.accounts(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, name)
);

-- ---------- Estados financieros configurables ----------
create table public.financial_statement_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  kind text not null check (kind in ('balance','income','other')),
  active boolean not null default true,
  unique (organization_id, name)
);
create table public.financial_statement_rows (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  template_id uuid not null references public.financial_statement_templates(id) on delete cascade,
  code text not null,
  label text not null,
  row_type text not null check (row_type in ('header','accounts','subtotal')),
  sort_order int not null default 0,
  formula text,
  sign smallint not null default 1 check (sign in (1,-1)),
  indent int not null default 0,
  unique (template_id, code)
);
create table public.financial_statement_mappings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  row_id uuid not null references public.financial_statement_rows(id) on delete cascade,
  account_id uuid not null references public.accounts(id),
  include_descendants boolean not null default true,
  unique (row_id, account_id)
);

-- ---------- Aprobaciones, adjuntos, auditoría, cierres ----------
create table public.approval_workflows (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_type text not null,
  required_approvals int not null default 1 check (required_approvals between 1 and 5),
  allow_self_approval boolean not null default false,
  active boolean not null default true,
  unique (organization_id, doc_type)
);
create table public.approval_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_type text not null,
  doc_id uuid not null,
  doc_label text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  required_approvals int not null,
  allow_self_approval boolean not null default false,
  submitted_by uuid references auth.users(id),
  submitted_at timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index approval_one_pending on public.approval_requests(doc_type, doc_id) where status = 'pending';
create index on public.approval_requests(organization_id, status);
create table public.approval_steps (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  request_id uuid not null references public.approval_requests(id) on delete cascade,
  approver_id uuid not null references auth.users(id),
  decision text not null check (decision in ('approved','rejected')),
  comment text,
  decided_at timestamptz not null default now(),
  unique (request_id, approver_id)
);
create table public.approval_history (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_type text not null,
  doc_id uuid not null,
  request_id uuid,
  action text not null,
  from_status text, to_status text,
  user_id uuid references auth.users(id),
  comment text,
  created_at timestamptz not null default now()
);
create index on public.approval_history(doc_type, doc_id);

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  storage_path text not null unique,
  file_name text not null,
  mime_type text,
  size_bytes bigint,
  uploaded_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.attachments(organization_id, entity_type, entity_id);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  organization_id uuid,
  user_id uuid,
  user_email text,
  action text not null,
  entity_type text not null,
  entity_id text,
  old_data jsonb, new_data jsonb,
  comment text,
  created_at timestamptz not null default now()
);
create index on public.audit_logs(organization_id, created_at desc);
create index on public.audit_logs(entity_type, entity_id);

create table public.accounting_close_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  period_id uuid not null references public.accounting_periods(id),
  action text not null check (action in ('close','reopen')),
  reason text,
  executed_by uuid references auth.users(id) default auth.uid(),
  executed_at timestamptz not null default now()
);
