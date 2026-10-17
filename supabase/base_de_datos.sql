-- #####################################################################
--  SISTEMA CONTABLE — INSTALACIÓN DE LA BASE DE DATOS (UN SOLO SCRIPT)
-- #####################################################################
--  CÓMO USAR ESTE ARCHIVO
--  1) Cambie SOLO las dos líneas marcadas con  <<<  (su correo y su clave)
--  2) Copie TODO el contenido y péguelo en Supabase > SQL Editor > New query
--  3) Presione el botón verde "Run". Debe terminar con "Success".
--
--  Este script se ejecuta UNA sola vez en un proyecto Supabase nuevo.
--  Crea tablas, seguridad, reglas contables, almacenamiento de archivos
--  y UN usuario administrador general con los datos que escriba aquí.
-- #####################################################################

create table public._instalacion as
select
  'TU_CORREO@ejemplo.com'::text      as email,       -- <<< 1) ESCRIBA AQUÍ SU CORREO (entre comillas)
  'TU_CLAVE_SEGURA_AQUI'::text       as password,    -- <<< 2) ESCRIBA AQUÍ SU CLAVE (mínimo 8 caracteres)
  'Administrador General'::text      as full_name;

do $$
declare e text; p text;
begin
  select email, password into e, p from public._instalacion;
  if e like 'TU\_CORREO%' or p like 'TU\_CLAVE%' then
    drop table public._instalacion;
    raise exception 'Antes de ejecutar, cambie TU_CORREO@ejemplo.com y TU_CLAVE_SEGURA_AQUI por sus datos reales (primeras líneas del script).';
  end if;
  if length(p) < 8 then
    drop table public._instalacion;
    raise exception 'La clave debe tener al menos 8 caracteres.';
  end if;
end $$;

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

-- =====================================================================
-- PARTE 2: ASIENTOS, COMPRAS, VENTAS, TESORERÍA, INVENTARIOS
-- (Todos los documentos comparten las columnas de estado/aprobación)
-- =====================================================================

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  entry_number bigint,
  entry_date date not null default current_date,
  description text not null default '',
  reference text,
  currency_code char(3) not null references public.currencies(code),
  exchange_rate numeric(18,8) not null default 1 check (exchange_rate > 0),
  entry_kind text not null default 'manual' check (entry_kind in ('manual','auto','reversal')),
  source_type text,
  source_id uuid,
  reverses_entry_id uuid references public.journal_entries(id),
  reversed_by_entry_id uuid references public.journal_entries(id),
  total_debit_base numeric(18,2) not null default 0,
  total_credit_base numeric(18,2) not null default 0,
  status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text
);
create unique index journal_entry_number_uk on public.journal_entries(organization_id, entry_number) where entry_number is not null;
create unique index journal_entry_source_uk on public.journal_entries(organization_id, source_type, source_id) where entry_kind = 'auto';
create index on public.journal_entries(organization_id, entry_date);

create table public.journal_entry_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  entry_id uuid not null references public.journal_entries(id) on delete cascade,
  line_no int not null default 0,
  account_id uuid not null references public.accounts(id),
  activity_id uuid references public.activities(id),
  description text,
  debit numeric(18,2) not null default 0 check (debit >= 0),
  credit numeric(18,2) not null default 0 check (credit >= 0),
  debit_base numeric(18,2) not null default 0 check (debit_base >= 0),
  credit_base numeric(18,2) not null default 0 check (credit_base >= 0),
  check (not (debit_base > 0 and credit_base > 0)),
  check (not (debit > 0 and credit > 0))
);
create index on public.journal_entry_lines(entry_id);
create index on public.journal_entry_lines(organization_id, account_id);
create index on public.journal_entry_lines(activity_id);

-- ---------- Compras ----------
create table public.purchase_invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_number text,
  supplier_id uuid not null references public.suppliers(id),
  supplier_doc_number text not null,
  authorization_number text,
  issue_date date not null default current_date,
  registration_date date not null default current_date,
  due_date date,
  currency_code char(3) not null references public.currencies(code),
  exchange_rate numeric(18,8) not null default 1 check (exchange_rate > 0),
  payment_form text not null default 'credit' check (payment_form in ('credit','cash')),
  subtotal numeric(18,2) not null default 0,
  tax_total numeric(18,2) not null default 0,
  total numeric(18,2) not null default 0,
  total_base numeric(18,2) not null default 0,
  paid_amount numeric(18,2) not null default 0,
  paid_base_carried numeric(18,2) not null default 0,
  notes text,
  journal_entry_id uuid references public.journal_entries(id),
  status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text
);
create unique index purchase_invoice_dup_uk on public.purchase_invoices(organization_id, supplier_id, supplier_doc_number) where status <> 'voided';
create unique index purchase_invoice_num_uk on public.purchase_invoices(organization_id, doc_number);
create index on public.purchase_invoices(organization_id, status);

create table public.purchase_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null references public.purchase_invoices(id) on delete cascade,
  line_no int not null default 0,
  line_kind text not null default 'expense' check (line_kind in ('inventory','expense','landed_cost')),
  product_id uuid references public.products(id),
  account_id uuid references public.accounts(id),
  description text,
  quantity numeric(18,4) not null default 1 check (quantity > 0),
  unit_price numeric(18,4) not null default 0 check (unit_price >= 0),
  discount numeric(18,2) not null default 0 check (discount >= 0),
  tax_type_id uuid references public.tax_types(id),
  tax_rate numeric(9,4) not null default 0,
  base_amount numeric(18,2) not null default 0,
  tax_amount numeric(18,2) not null default 0,
  line_total numeric(18,2) not null default 0,
  activity_id uuid references public.activities(id),
  check (line_kind <> 'inventory' or product_id is not null)
);
create index on public.purchase_invoice_lines(invoice_id);

create table public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_number text,
  supplier_id uuid not null references public.suppliers(id),
  payment_date date not null default current_date,
  cash_bank_account_id uuid not null references public.cash_bank_accounts(id),
  payment_method_id uuid references public.payment_methods(id),
  currency_code char(3) not null references public.currencies(code),
  exchange_rate numeric(18,8) not null default 1 check (exchange_rate > 0),
  amount numeric(18,2) not null check (amount > 0),
  reference text,
  notes text,
  journal_entry_id uuid references public.journal_entries(id),
  status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text
);
create unique index supplier_payment_num_uk on public.supplier_payments(organization_id, doc_number);
create table public.supplier_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  payment_id uuid not null references public.supplier_payments(id) on delete cascade,
  invoice_id uuid not null references public.purchase_invoices(id),
  amount numeric(18,2) not null check (amount > 0),
  carried_base numeric(18,2),
  unique (payment_id, invoice_id)
);
create index on public.supplier_payment_allocations(invoice_id);

-- ---------- Ventas ----------
create table public.sales_invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_number text,
  customer_id uuid not null references public.customers(id),
  invoice_number text not null,
  authorization_number text,
  issue_date date not null default current_date,
  due_date date,
  currency_code char(3) not null references public.currencies(code),
  exchange_rate numeric(18,8) not null default 1 check (exchange_rate > 0),
  subtotal numeric(18,2) not null default 0,
  tax_total numeric(18,2) not null default 0,
  total numeric(18,2) not null default 0,
  total_base numeric(18,2) not null default 0,
  paid_amount numeric(18,2) not null default 0,
  paid_base_carried numeric(18,2) not null default 0,
  notes text,
  journal_entry_id uuid references public.journal_entries(id),
  status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text
);
create unique index sales_invoice_dup_uk on public.sales_invoices(organization_id, invoice_number) where status <> 'voided';
create unique index sales_invoice_num_uk on public.sales_invoices(organization_id, doc_number);
create index on public.sales_invoices(organization_id, status);

create table public.sales_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null references public.sales_invoices(id) on delete cascade,
  line_no int not null default 0,
  product_id uuid references public.products(id),
  account_id uuid references public.accounts(id),
  description text,
  quantity numeric(18,4) not null default 1 check (quantity > 0),
  unit_price numeric(18,4) not null default 0 check (unit_price >= 0),
  discount numeric(18,2) not null default 0 check (discount >= 0),
  tax_type_id uuid references public.tax_types(id),
  tax_rate numeric(9,4) not null default 0,
  base_amount numeric(18,2) not null default 0,
  tax_amount numeric(18,2) not null default 0,
  line_total numeric(18,2) not null default 0,
  activity_id uuid references public.activities(id)
);
create index on public.sales_invoice_lines(invoice_id);

create table public.customer_receipts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_number text,
  customer_id uuid not null references public.customers(id),
  receipt_date date not null default current_date,
  cash_bank_account_id uuid not null references public.cash_bank_accounts(id),
  payment_method_id uuid references public.payment_methods(id),
  currency_code char(3) not null references public.currencies(code),
  exchange_rate numeric(18,8) not null default 1 check (exchange_rate > 0),
  amount numeric(18,2) not null check (amount > 0),
  reference text,
  notes text,
  journal_entry_id uuid references public.journal_entries(id),
  status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text
);
create unique index customer_receipt_num_uk on public.customer_receipts(organization_id, doc_number);
create table public.customer_receipt_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  receipt_id uuid not null references public.customer_receipts(id) on delete cascade,
  invoice_id uuid not null references public.sales_invoices(id),
  amount numeric(18,2) not null check (amount > 0),
  carried_base numeric(18,2),
  unique (receipt_id, invoice_id)
);
create index on public.customer_receipt_allocations(invoice_id);

-- ---------- Caja y bancos: ingresos, egresos y transferencias ----------
create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_number text,
  movement_type text not null check (movement_type in ('income','expense','transfer')),
  movement_date date not null default current_date,
  cash_bank_account_id uuid not null references public.cash_bank_accounts(id),
  to_cash_bank_account_id uuid references public.cash_bank_accounts(id),
  counter_account_id uuid references public.accounts(id),
  activity_id uuid references public.activities(id),
  currency_code char(3) not null references public.currencies(code),
  exchange_rate numeric(18,8) not null default 1 check (exchange_rate > 0),
  amount numeric(18,2) not null check (amount > 0),
  description text,
  reference text,
  journal_entry_id uuid references public.journal_entries(id),
  status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text,
  check ((movement_type = 'transfer' and to_cash_bank_account_id is not null and to_cash_bank_account_id <> cash_bank_account_id)
      or (movement_type <> 'transfer' and counter_account_id is not null))
);
create unique index cash_movement_num_uk on public.cash_movements(organization_id, doc_number);

-- ---------- Inventarios ----------
create table public.inventory_adjustments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_number text,
  adjustment_date date not null default current_date,
  reason text not null default '',
  journal_entry_id uuid references public.journal_entries(id),
  status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text
);
create unique index inventory_adjustment_num_uk on public.inventory_adjustments(organization_id, doc_number);
create table public.inventory_adjustment_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  adjustment_id uuid not null references public.inventory_adjustments(id) on delete cascade,
  line_no int not null default 0,
  product_id uuid not null references public.products(id),
  quantity_delta numeric(18,4) not null check (quantity_delta <> 0),
  unit_cost numeric(18,6) not null default 0 check (unit_cost >= 0),
  activity_id uuid references public.activities(id)
);
create index on public.inventory_adjustment_lines(adjustment_id);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id),
  movement_date date not null,
  movement_type text not null check (movement_type in ('purchase_in','sale_out','adjust_in','adjust_out','purchase_return_out','sale_return_in')),
  quantity numeric(18,4) not null,
  unit_cost numeric(18,6) not null default 0,
  total_cost numeric(18,2) not null default 0,
  source_type text not null,
  source_id uuid not null,
  source_line_id uuid,
  journal_entry_id uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.inventory_movements(organization_id, product_id, movement_date);
create index on public.inventory_movements(source_type, source_id);

create table public.inventory_cost_layers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id),
  movement_id uuid not null references public.inventory_movements(id),
  seq bigint generated always as identity,
  layer_date date not null,
  qty_initial numeric(18,4) not null,
  qty_remaining numeric(18,4) not null check (qty_remaining >= 0),
  unit_cost numeric(18,6) not null,
  value_remaining numeric(18,2) not null,
  created_at timestamptz not null default now()
);
create index on public.inventory_cost_layers(product_id, layer_date, seq) where qty_remaining > 0;

-- ---------- Bancos: extractos y conciliación ----------
create table public.bank_statement_imports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  cash_bank_account_id uuid not null references public.cash_bank_accounts(id),
  file_name text not null,
  file_hash text not null,
  period_from date, period_to date,
  currency_code char(3),
  line_count int not null default 0,
  duplicate_count int not null default 0,
  column_mapping jsonb,
  status text not null default 'imported',
  imported_by uuid references auth.users(id) default auth.uid(),
  imported_at timestamptz not null default now(),
  unique (cash_bank_account_id, file_hash)
);
create table public.bank_statement_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  import_id uuid not null references public.bank_statement_imports(id) on delete cascade,
  cash_bank_account_id uuid not null references public.cash_bank_accounts(id),
  line_date date not null,
  value_date date,
  description text,
  reference text,
  external_id text,
  debit numeric(18,2) not null default 0 check (debit >= 0),
  credit numeric(18,2) not null default 0 check (credit >= 0),
  balance numeric(18,2),
  dedupe_key text not null,
  match_status text not null default 'unmatched' check (match_status in ('unmatched','partial','matched','ignored')),
  matched_amount numeric(18,2) not null default 0,
  unique (cash_bank_account_id, dedupe_key)
);
create index on public.bank_statement_lines(cash_bank_account_id, line_date);

create table public.bank_reconciliations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  doc_number text,
  cash_bank_account_id uuid not null references public.cash_bank_accounts(id),
  period_from date not null,
  period_to date not null,
  statement_balance numeric(18,2) not null default 0,
  notes text,
  status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text,
  check (period_to >= period_from)
);
create unique index bank_reconciliation_num_uk on public.bank_reconciliations(organization_id, doc_number);
create table public.bank_reconciliation_matches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  reconciliation_id uuid not null references public.bank_reconciliations(id) on delete cascade,
  statement_line_id uuid not null references public.bank_statement_lines(id),
  journal_line_id uuid not null references public.journal_entry_lines(id),
  amount numeric(18,2) not null check (amount > 0),
  match_type text not null default 'manual' check (match_type in ('auto','manual')),
  status text not null default 'active' check (status in ('active','undone')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  undone_by uuid, undone_at timestamptz, undone_reason text
);
create index on public.bank_reconciliation_matches(statement_line_id) where status = 'active';
create index on public.bank_reconciliation_matches(journal_line_id) where status = 'active';
create table public.bank_reconciliation_adjustments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  reconciliation_id uuid not null references public.bank_reconciliations(id) on delete cascade,
  statement_line_id uuid not null references public.bank_statement_lines(id),
  adjustment_type text not null default 'fee' check (adjustment_type in ('fee','interest','charge','other')),
  description text,
  counter_account_id uuid not null references public.accounts(id),
  journal_entry_id uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique (statement_line_id)
);

-- =====================================================================
-- PARTE 3: SEGURIDAD, GUARDAS DE INTEGRIDAD Y AUDITORÍA
-- =====================================================================

-- ---------- Funciones de acceso (usadas por las políticas RLS) ----------
create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_platform_admin and p.active from profiles p where p.id = auth.uid()), false)
$$;

create or replace function public.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from organization_members m join profiles p on p.id = m.user_id
    where m.organization_id = p_org and m.user_id = auth.uid() and m.active and p.active)
$$;

create or replace function public.has_perm(p_org uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from organization_members m
    join profiles p on p.id = m.user_id
    join role_permissions rp on rp.organization_id = m.organization_id and rp.role = m.role
    where m.organization_id = p_org and m.user_id = auth.uid() and m.active and p.active
      and rp.permission = p_perm)
$$;

create or replace function public.my_permissions(p_org uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(rp.permission order by rp.permission), '{}')
  from organization_members m
  join profiles p on p.id = m.user_id
  join role_permissions rp on rp.organization_id = m.organization_id and rp.role = m.role
  where m.organization_id = p_org and m.user_id = auth.uid() and m.active and p.active
$$;

-- ---------- Utilidades internas ----------
create or replace function app_private.flag_on() returns boolean language sql stable as $$
  select coalesce(current_setting('app.allow_post', true), 'off') = 'on'
$$;

create or replace function app_private.require_perm(p_org uuid, p_perm text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Debe iniciar sesión.'; end if;
  if not public.has_perm(p_org, p_perm) then
    raise exception 'No tiene permiso para esta operación (%).', p_perm using errcode = '42501';
  end if;
end $$;

create or replace function app_private.log_audit(p_org uuid, p_action text, p_type text, p_id text,
  p_comment text default null, p_old jsonb default null, p_new jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_logs(organization_id, user_id, user_email, action, entity_type, entity_id, old_data, new_data, comment)
  values (p_org, auth.uid(), (select email from profiles where id = auth.uid()), p_action, p_type, p_id, p_old, p_new, p_comment);
end $$;

create or replace function app_private.assert_period_open(p_org uuid, p_date date) returns void
language plpgsql stable security definer set search_path = public as $$
declare st text;
begin
  select status into st from accounting_periods
   where organization_id = p_org and p_date between start_date and end_date;
  if st is null then raise exception 'No existe un periodo contable para la fecha % . Cree el periodo en Configuración > Periodos.', p_date; end if;
  if st <> 'open' then raise exception 'El periodo contable de la fecha % está cerrado.', p_date; end if;
end $$;

create or replace function app_private.next_seq(p_org uuid, p_type text) returns bigint
language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  insert into document_sequences(organization_id, doc_type) values (p_org, p_type) on conflict do nothing;
  update document_sequences set next_number = next_number + 1
   where organization_id = p_org and doc_type = p_type returning next_number - 1 into n;
  return n;
end $$;

create or replace function app_private.next_doc_number(p_org uuid, p_type text) returns text
language plpgsql security definer set search_path = public as $$
declare n bigint; pre text; pad int;
begin
  n := app_private.next_seq(p_org, p_type);
  select prefix, padding into pre, pad from document_sequences where organization_id = p_org and doc_type = p_type;
  return pre || lpad(n::text, pad, '0');
end $$;

-- ---------- Triggers genéricos ----------
-- Asigna número interno al crear un documento
create or replace function app_private.trg_assign_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.doc_number is null or new.doc_number = '' then
    new.doc_number := app_private.next_doc_number(new.organization_id, tg_argv[0]);
  end if;
  return new;
end $$;

-- Verifica que las referencias pertenezcan a la misma empresa. Argumentos: 'columna:tabla'
create or replace function app_private.trg_same_org() returns trigger
language plpgsql security definer set search_path = public as $$
declare a text; col text; tbl text; v jsonb := to_jsonb(new); rid text; o uuid;
begin
  foreach a in array tg_argv loop
    col := split_part(a, ':', 1); tbl := split_part(a, ':', 2);
    rid := v ->> col;
    if rid is not null then
      execute format('select organization_id from public.%I where id = $1', tbl) into o using rid::uuid;
      if o is null or o is distinct from new.organization_id then
        raise exception 'La referencia % pertenece a otra empresa o no existe.', col;
      end if;
    end if;
  end loop;
  return new;
end $$;

-- Protege columnas de sistema. Argumentos: 'columna=valor_json_inicial'
create or replace function app_private.trg_protect() returns trigger
language plpgsql security definer set search_path = public as $$
declare v jsonb; a text; k text; val jsonb;
begin
  if app_private.flag_on() then return new; end if;
  v := to_jsonb(new);
  foreach a in array tg_argv loop
    k := split_part(a, '=', 1); val := substr(a, length(k) + 2)::jsonb;
    if tg_op = 'INSERT' then v := jsonb_set(v, array[k], val);
    else v := jsonb_set(v, array[k], coalesce(to_jsonb(old) -> k, 'null'::jsonb)); end if;
  end loop;
  new := jsonb_populate_record(new, v);
  return new;
end $$;

-- Guarda de documentos: solo se editan en borrador/rechazado; el estado cambia solo por el flujo
create or replace function app_private.trg_guard_document() returns trigger
language plpgsql security definer set search_path = public as $$
declare v jsonb; a text; k text; val jsonb;
begin
  if app_private.flag_on() then
    if tg_op = 'DELETE' then return old; end if;
    new.updated_at := now(); return new;
  end if;
  if tg_op = 'DELETE' then
    if old.status not in ('draft','rejected') then
      raise exception 'Un documento en estado "%" no puede eliminarse. Use anulación o reversión.', old.status;
    end if;
    return old;
  end if;
  v := to_jsonb(new);
  if tg_op = 'INSERT' then
    v := v || jsonb_build_object('status','draft','posted_by',null,'posted_at',null,'approved_at',null,
                                 'submitted_at',null,'rejection_reason',null,
                                 'created_by', coalesce(to_jsonb(auth.uid()), 'null'::jsonb));
  else
    if old.status not in ('draft','rejected') then
      raise exception 'El documento está en estado "%" y no puede modificarse. Devuélvalo a borrador para editarlo (se invalidarán las aprobaciones).', old.status;
    end if;
    v := v || jsonb_build_object('status', to_jsonb(old.status), 'posted_by', to_jsonb(old.posted_by),
      'posted_at', to_jsonb(old.posted_at), 'approved_at', to_jsonb(old.approved_at),
      'submitted_at', to_jsonb(old.submitted_at), 'rejection_reason', to_jsonb(old.rejection_reason),
      'created_by', to_jsonb(old.created_by), 'organization_id', to_jsonb(old.organization_id));
  end if;
  foreach a in array tg_argv loop
    k := split_part(a, '=', 1); val := substr(a, length(k) + 2)::jsonb;
    if tg_op = 'INSERT' then v := jsonb_set(v, array[k], val);
    else v := jsonb_set(v, array[k], coalesce(to_jsonb(old) -> k, 'null'::jsonb)); end if;
  end loop;
  new := jsonb_populate_record(new, v);
  new.updated_at := now();
  return new;
end $$;

-- Guarda de líneas: el documento padre debe ser editable y de la misma empresa
create or replace function app_private.trg_guard_line() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid; st public.doc_status; porg uuid; r record;
begin
  if app_private.flag_on() then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  r := case when tg_op = 'DELETE' then old else new end;
  pid := (to_jsonb(r) ->> tg_argv[1])::uuid;
  execute format('select status, organization_id from public.%I where id = $1', tg_argv[0]) into st, porg using pid;
  if st is null then
    if tg_op = 'DELETE' then return old; end if;   -- borrado en cascada del documento padre
    raise exception 'Documento padre inexistente.';
  end if;
  if st not in ('draft','rejected') then
    raise exception 'El documento está en estado "%" y sus líneas no pueden modificarse.', st;
  end if;
  if tg_op <> 'DELETE' and porg is distinct from new.organization_id then
    raise exception 'La línea debe pertenecer a la misma empresa que el documento.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- Cálculo de línea de factura (compras/ventas)
create or replace function app_private.trg_calc_invoice_line() returns trigger
language plpgsql security definer set search_path = public as $$
declare r numeric := 0;
begin
  if new.line_no is null or new.line_no = 0 then
    execute format('select coalesce(max(line_no),0)+1 from public.%I where invoice_id = $1', tg_table_name) into new.line_no using new.invoice_id;
  end if;
  new.base_amount := round(new.quantity * new.unit_price - new.discount, 2);
  if new.base_amount < 0 then raise exception 'El descuento no puede superar el importe de la línea.'; end if;
  if new.tax_type_id is not null then
    select rate into r from tax_types where id = new.tax_type_id and organization_id = new.organization_id;
    if r is null then raise exception 'Impuesto inválido.'; end if;
  end if;
  new.tax_rate := coalesce(r, 0);
  new.tax_amount := round(new.base_amount * new.tax_rate / 100, 2);
  new.line_total := new.base_amount + new.tax_amount;
  return new;
end $$;

create or replace function app_private.recalc_totals(p_table text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare prev text := coalesce(current_setting('app.allow_post', true), 'off');
begin
  perform set_config('app.allow_post', 'on', true);
  if p_table in ('purchase_invoices','sales_invoices') then
    execute format($f$update public.%I h set subtotal = s.sub, tax_total = s.tax, total = s.sub + s.tax
      from (select coalesce(sum(base_amount),0) sub, coalesce(sum(tax_amount),0) tax from public.%I where invoice_id = $1) s
      where h.id = $1$f$, p_table, replace(p_table, 'invoices', 'invoice_lines')) using p_id;
  elsif p_table = 'journal_entries' then
    update journal_entries e set total_debit_base = s.d, total_credit_base = s.c
      from (select coalesce(sum(debit_base),0) d, coalesce(sum(credit_base),0) c from journal_entry_lines where entry_id = p_id) s
      where e.id = p_id;
  end if;
  perform set_config('app.allow_post', prev, true);
end $$;

create or replace function app_private.trg_after_line() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid; r record;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  pid := (to_jsonb(r) ->> tg_argv[1])::uuid;
  perform app_private.recalc_totals(tg_argv[0], pid);
  return null;
end $$;

-- Líneas de asiento manual: importes en moneda base siempre calculados por el sistema
create or replace function app_private.trg_calc_journal_line() returns trigger
language plpgsql security definer set search_path = public as $$
declare rate numeric; ok boolean;
begin
  if new.line_no is null or new.line_no = 0 then
    select coalesce(max(line_no),0)+1 into new.line_no from journal_entry_lines where entry_id = new.entry_id;
  end if;
  if app_private.flag_on() then return new; end if;
  select exchange_rate into rate from journal_entries where id = new.entry_id;
  new.debit_base := round(new.debit * rate, 2);
  new.credit_base := round(new.credit * rate, 2);
  select (is_postable and active) into ok from accounts where id = new.account_id;
  if not coalesce(ok, false) then raise exception 'La cuenta seleccionada no admite movimientos o está inactiva.'; end if;
  return new;
end $$;

-- Inmutabilidad de asientos contabilizados
create or replace function app_private.trg_journal_immutable() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.status in ('posted','voided') and not app_private.flag_on() then
      raise exception 'Un asiento contabilizado no puede eliminarse; use una reversión autorizada.';
    end if;
    return old;
  end if;
  return new;
end $$;

-- Auditoría automática de cambios en tablas importantes
create or replace function app_private.trg_audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; k text; dold jsonb := '{}'; dnew jsonb := '{}'; j jsonb; org uuid; eid text;
begin
  if tg_op = 'INSERT' then n := to_jsonb(new); j := n;
  elsif tg_op = 'DELETE' then o := to_jsonb(old); j := o;
  else
    o := to_jsonb(old); n := to_jsonb(new); j := n;
    for k in select jsonb_object_keys(n) loop
      if k <> 'updated_at' and (o -> k) is distinct from (n -> k) then
        dold := dold || jsonb_build_object(k, o -> k); dnew := dnew || jsonb_build_object(k, n -> k);
      end if;
    end loop;
    if dnew = '{}'::jsonb then return new; end if;
    o := dold; n := dnew;
  end if;
  if tg_table_name = 'organizations' then org := (j ->> 'id')::uuid; else org := (j ->> 'organization_id')::uuid; end if;
  eid := coalesce(j ->> 'id', j ->> 'user_id', concat_ws(':', j ->> 'role', j ->> 'permission', j ->> 'rule_key', j ->> 'doc_type'));
  insert into audit_logs(organization_id, user_id, user_email, action, entity_type, entity_id, old_data, new_data)
  values (org, auth.uid(), (select email from profiles where id = auth.uid()), lower(tg_op), tg_table_name, eid, o, n);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create or replace function app_private.trg_audit_immutable() returns trigger
language plpgsql as $$
begin raise exception 'El registro de auditoría no puede modificarse ni eliminarse.'; end $$;

create trigger audit_logs_immutable before update or delete on public.audit_logs
  for each row execute function app_private.trg_audit_immutable();

-- ---------- Guardas específicas ----------
create or replace function app_private.trg_guard_account() returns trigger
language plpgsql security definer set search_path = public as $$
declare used boolean; p uuid; depth int := 0;
begin
  if tg_op = 'UPDATE' then
    select exists(select 1 from journal_entry_lines where account_id = old.id) into used;
    if used and (new.code <> old.code or new.account_type <> old.account_type or new.nature <> old.nature
                 or (old.is_postable and not new.is_postable)) then
      raise exception 'La cuenta % ya tiene movimientos: no puede cambiar su código, tipo, naturaleza ni dejar de ser de movimiento.', old.code;
    end if;
    if new.parent_id = new.id then raise exception 'Una cuenta no puede ser su propia cuenta padre.'; end if;
  end if;
  p := new.parent_id;
  while p is not null and depth < 30 loop
    if p = new.id then raise exception 'La jerarquía de cuentas no puede tener ciclos.'; end if;
    select parent_id into p from accounts where id = p; depth := depth + 1;
  end loop;
  return new;
end $$;

create or replace function app_private.trg_guard_posting_account() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from accounts a where a.id = new.account_id and not a.is_postable) then
    raise exception 'La cuenta de agrupación no admite movimientos directos.';
  end if;
  return new;
end $$;

create or replace function app_private.trg_guard_org() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app_private.flag_on() then return new; end if;
  if new.base_currency <> old.base_currency and exists(select 1 from journal_entries where organization_id = old.id) then
    raise exception 'No puede cambiar la moneda base: la empresa ya tiene asientos.';
  end if;
  new.created_by := old.created_by; new.created_at := old.created_at; new.updated_at := now();
  return new;
end $$;

create or replace function app_private.trg_guard_inv_settings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from inventory_movements where organization_id = old.organization_id)
     and (new.valuation_method <> old.valuation_method or new.cost_decimals <> old.cost_decimals) then
    raise exception 'La empresa ya tiene movimientos de inventario. El cambio de método de valoración requiere un proceso formal autorizado (no disponible en esta versión).';
  end if;
  new.updated_at := now();
  return new;
end $$;

create or replace function app_private.trg_guard_product() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app_private.flag_on() then return new; end if;
  if tg_op = 'UPDATE' and new.product_type <> old.product_type
     and exists(select 1 from inventory_movements where product_id = old.id) then
    raise exception 'No puede cambiar el tipo de un producto con movimientos de inventario.';
  end if;
  return new;
end $$;

create or replace function app_private.trg_guard_sequence() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app_private.flag_on() then return new; end if;
  if new.next_number < old.next_number then
    raise exception 'La numeración no puede retroceder.';
  end if;
  return new;
end $$;

create or replace function app_private.trg_guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app_private.flag_on() then return new; end if;
  new.is_platform_admin := old.is_platform_admin; new.active := old.active;
  new.email := old.email; new.id := old.id;
  return new;
end $$;

create or replace function app_private.trg_immutable_rows() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app_private.flag_on() then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  raise exception 'Este registro es generado por el sistema y no puede modificarse directamente.';
end $$;

create or replace function app_private.trg_auto_line_no() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.line_no is null or new.line_no = 0 then
    execute format('select coalesce(max(line_no),0)+1 from public.%I where %I = $1', tg_table_name, tg_argv[0])
      into new.line_no using (to_jsonb(new) ->> tg_argv[0])::uuid;
  end if;
  return new;
end $$;

-- =====================================================================
-- PARTE 4: EMPRESAS, USUARIOS, PERMISOS Y PERIODOS
-- =====================================================================

create or replace function app_private.all_permissions() returns text[] language sql immutable as $$
  select array['data.view','config.manage','users.manage','audit.view','accounts.manage','masters.manage',
    'purchases.create','sales.create','payments.create','receipts.create','treasury.create','journal.create','inventory.create',
    'documents.submit','documents.approve','documents.post','documents.reverse',
    'periods.close','periods.reopen','bank.import','bank.reconcile','reports.export','attachments.manage']
$$;

create or replace function app_private.seed_role_permissions(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select * from (values
    ('admin', 'data.view,config.manage,users.manage,audit.view,masters.manage,documents.approve,reports.export,attachments.manage'),
    ('accountant', 'data.view,accounts.manage,masters.manage,purchases.create,sales.create,payments.create,receipts.create,treasury.create,journal.create,inventory.create,documents.submit,documents.approve,documents.post,documents.reverse,periods.close,periods.reopen,bank.import,bank.reconcile,reports.export,attachments.manage'),
    ('assistant', 'data.view,masters.manage,purchases.create,sales.create,payments.create,receipts.create,treasury.create,journal.create,inventory.create,documents.submit,bank.import,bank.reconcile,attachments.manage'),
    ('purchasing', 'data.view,masters.manage,purchases.create,payments.create,documents.submit,attachments.manage'),
    ('auditor', 'data.view,audit.view,reports.export')
  ) as t(role, perms) loop
    insert into role_permissions(organization_id, role, permission)
    select p_org, r.role::app_role, unnest(string_to_array(r.perms, ',')) on conflict do nothing;
  end loop;
end $$;

create or replace function app_private.seed_organization(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s text; parts text[]; r record; t uuid; rid uuid; m text; dt text;
begin
  perform set_config('app.allow_post', 'on', true);
  -- Plan de cuentas sugerido (editable)
  foreach s in array array[
   '1|ACTIVO||asset|debit|f','11|Activo corriente|1|asset|debit|f',
   '1101|Caja|11|asset|debit|t','1102|Bancos|11|asset|debit|t','1103|Cuentas por cobrar clientes|11|asset|debit|t',
   '1104|IVA crédito fiscal|11|asset|debit|t','1105|Inventarios|11|asset|debit|t','1106|Anticipos a proveedores|11|asset|debit|t',
   '12|Activo no corriente|1|asset|debit|f','1201|Muebles y equipos|12|asset|debit|t','1202|(-) Depreciación acumulada|12|asset|credit|t',
   '2|PASIVO||liability|credit|f','21|Pasivo corriente|2|liability|credit|f',
   '2101|Cuentas por pagar proveedores|21|liability|credit|t','2102|IVA débito fiscal|21|liability|credit|t',
   '2103|Impuestos por pagar|21|liability|credit|t','2104|Sueldos y cargas sociales por pagar|21|liability|credit|t',
   '2105|Anticipos de clientes|21|liability|credit|t',
   '3|PATRIMONIO||equity|credit|f','3101|Capital|3|equity|credit|t','3102|Resultados acumulados|3|equity|credit|t','3103|Resultado de la gestión|3|equity|credit|t',
   '4|INGRESOS||revenue|credit|f','41|Ingresos de operación|4|revenue|credit|f',
   '4101|Ventas de mercaderías|41|revenue|credit|t','4102|Ingresos por servicios|41|revenue|credit|t',
   '42|Otros ingresos|4|revenue|credit|f','4103|Otros ingresos|42|revenue|credit|t','4104|Ganancia por diferencia de cambio|42|revenue|credit|t',
   '5|COSTOS||cost|debit|f','5101|Costo de ventas|5|cost|debit|t','5102|Ajustes de inventario|5|cost|debit|t',
   '6|GASTOS||expense|debit|f','61|Gastos de administración|6|expense|debit|f',
   '6101|Sueldos y salarios|61|expense|debit|t','6102|Alquileres|61|expense|debit|t','6103|Servicios básicos|61|expense|debit|t',
   '6104|Honorarios profesionales|61|expense|debit|t','6105|Gastos generales|61|expense|debit|t',
   '62|Gastos de venta|6|expense|debit|f','6201|Publicidad y promoción|62|expense|debit|t',
   '63|Gastos financieros|6|expense|debit|f','6301|Comisiones bancarias|63|expense|debit|t','6302|Intereses pagados|63|expense|debit|t',
   '6303|Pérdida por diferencia de cambio|63|expense|debit|t'] loop
    parts := string_to_array(s, '|');
    insert into accounts(organization_id, code, name, parent_id, account_type, nature, is_postable)
    values (p_org, parts[1], parts[2], (select id from accounts where organization_id = p_org and code = nullif(parts[3], '')),
            parts[4], parts[5], parts[6] = 't');
  end loop;

  insert into accounting_rules(organization_id, rule_key, account_id)
  select p_org, k, (select id from accounts where organization_id = p_org and code = c)
  from (values ('purchase.payable','2101'),('purchase.expense','6105'),('sales.receivable','1103'),('sales.revenue','4101'),
               ('sales.cogs','5101'),('inventory.asset','1105'),('inventory.adjustment','5102'),
               ('fx.gain','4104'),('fx.loss','6303')) v(k, c);

  -- Impuestos de ejemplo (EDITABLES: verifique tasas y tratamiento con su contador)
  insert into tax_types(organization_id, code, name, rate, category, applies_to, treatment, account_id, notes)
  values
   (p_org,'IVA-C13','IVA crédito fiscal 13% (ejemplo)',13,'IVA','purchase','recoverable',(select id from accounts where organization_id=p_org and code='1104'),'Tasa de ejemplo: verificar normativa vigente.'),
   (p_org,'IVA-D13','IVA débito fiscal 13% (ejemplo)',13,'IVA','sales','payable',(select id from accounts where organization_id=p_org and code='2102'),'Tasa de ejemplo: verificar normativa vigente.'),
   (p_org,'EXE-C','Exento / sin impuesto (compras)',0,'Exento','purchase','cost',null,null),
   (p_org,'EXE-V','Exento / sin impuesto (ventas)',0,'Exento','sales','payable',(select id from accounts where organization_id=p_org and code='2102'),null);

  insert into document_sequences(organization_id, doc_type, prefix, padding) values
   (p_org,'purchase_invoice','CP-',5),(p_org,'sales_invoice','VT-',5),(p_org,'supplier_payment','PG-',5),
   (p_org,'customer_receipt','CB-',5),(p_org,'journal_entry','',6),(p_org,'inventory_adjustment','AJ-',5),
   (p_org,'cash_movement','MT-',5),(p_org,'bank_reconciliation','CO-',5)
  on conflict do nothing;

  insert into payment_methods(organization_id, name, kind) values
   (p_org,'Efectivo','cash'),(p_org,'Transferencia bancaria','bank_transfer'),(p_org,'Cheque','check'),(p_org,'Tarjeta','card');

  insert into inventory_settings(organization_id) values (p_org) on conflict do nothing;

  foreach dt in array array['purchase_invoice','sales_invoice','supplier_payment','customer_receipt','journal_entry',
                            'inventory_adjustment','cash_movement','bank_reconciliation'] loop
    insert into approval_workflows(organization_id, doc_type) values (p_org, dt) on conflict do nothing;
  end loop;

  insert into activities(organization_id, code, name, description) values (p_org,'GEN','General','Actividad por defecto');

  insert into cash_bank_accounts(organization_id, name, kind, currency_code, account_id)
  select p_org, 'Caja general', 'cash', o.base_currency, (select id from accounts where organization_id=p_org and code='1101')
  from organizations o where o.id = p_org;

  perform app_private.seed_role_permissions(p_org);
  perform app_private.gen_periods(p_org, extract(year from current_date)::int);

  -- Plantillas de estados financieros
  insert into financial_statement_templates(organization_id, name, kind) values
   (p_org,'Estado de situación financiera','balance'),(p_org,'Estado de resultados','income');
  foreach s in array array[
   'Estado de situación financiera|A0|ACTIVO|header|10||1|0|',
   'Estado de situación financiera|A1|Activo corriente|accounts|20||1|1|11',
   'Estado de situación financiera|A2|Activo no corriente|accounts|30||1|1|12',
   'Estado de situación financiera|AT|TOTAL ACTIVO|subtotal|40|A1+A2|1|0|',
   'Estado de situación financiera|P0|PASIVO|header|50||1|0|',
   'Estado de situación financiera|P1|Pasivo corriente|accounts|60||-1|1|21',
   'Estado de situación financiera|PT|TOTAL PASIVO|subtotal|70|P1|1|0|',
   'Estado de situación financiera|E0|PATRIMONIO|header|80||1|0|',
   'Estado de situación financiera|E1|Capital y resultados acumulados|accounts|90||-1|1|3',
   'Estado de situación financiera|E2|Resultado del periodo (no cerrado)|accounts|100||-1|1|4,5,6',
   'Estado de situación financiera|ET|TOTAL PATRIMONIO|subtotal|110|E1+E2|1|0|',
   'Estado de situación financiera|PP|TOTAL PASIVO Y PATRIMONIO|subtotal|120|PT+ET|1|0|',
   'Estado de resultados|I1|Ingresos de operación|accounts|10||-1|0|41',
   'Estado de resultados|C1|Costo de ventas|accounts|20||1|0|5',
   'Estado de resultados|UB|UTILIDAD BRUTA|subtotal|30|I1-C1|1|0|',
   'Estado de resultados|G1|Gastos de administración|accounts|40||1|1|61',
   'Estado de resultados|G2|Gastos de venta|accounts|50||1|1|62',
   'Estado de resultados|G3|Gastos financieros|accounts|60||1|1|63',
   'Estado de resultados|GT|TOTAL GASTOS|subtotal|70|G1+G2+G3|1|0|',
   'Estado de resultados|I2|Otros ingresos|accounts|80||-1|0|42',
   'Estado de resultados|UN|UTILIDAD (PÉRDIDA) DEL PERIODO|subtotal|90|UB-GT+I2|1|0|'] loop
    parts := string_to_array(s, '|');
    select id into t from financial_statement_templates where organization_id = p_org and name = parts[1];
    insert into financial_statement_rows(organization_id, template_id, code, label, row_type, sort_order, formula, sign, indent)
    values (p_org, t, parts[2], parts[3], parts[4], parts[5]::int, nullif(parts[6], ''), parts[7]::smallint, parts[8]::int)
    returning id into rid;
    if parts[9] <> '' then
      foreach m in array string_to_array(parts[9], ',') loop
        insert into financial_statement_mappings(organization_id, row_id, account_id, include_descendants)
        values (p_org, rid, (select id from accounts where organization_id = p_org and code = m), true);
      end loop;
    end if;
  end loop;
  perform set_config('app.allow_post', 'off', true);
end $$;

create or replace function app_private.gen_periods(p_org uuid, p_year int) returns void
language plpgsql security definer set search_path = public as $$
declare m int; d date;
begin
  for m in 1..12 loop
    d := make_date(p_year, m, 1);
    insert into accounting_periods(organization_id, name, start_date, end_date)
    values (p_org, to_char(d, 'YYYY-MM'), d, (d + interval '1 month - 1 day')::date)
    on conflict (organization_id, start_date) do nothing;
  end loop;
end $$;

-- ---------- Crear empresa ----------
create or replace function public.create_organization(p_legal_name text, p_trade_name text, p_tax_id text,
  p_address text, p_currency char(3)) returns uuid
language plpgsql security definer set search_path = public as $$
declare oid uuid;
begin
  if not public.is_platform_admin() then raise exception 'Solo el administrador general puede crear empresas.' using errcode = '42501'; end if;
  if coalesce(trim(p_legal_name), '') = '' then raise exception 'La razón social es obligatoria.'; end if;
  insert into organizations(legal_name, trade_name, tax_id, fiscal_address, base_currency, created_by)
  values (trim(p_legal_name), nullif(trim(p_trade_name), ''), nullif(trim(p_tax_id), ''), nullif(trim(p_address), ''), p_currency, auth.uid())
  returning id into oid;
  insert into organization_members(organization_id, user_id, role) values (oid, auth.uid(), 'admin');
  perform app_private.seed_organization(oid);
  perform app_private.log_audit(oid, 'create_organization', 'organizations', oid::text, 'Empresa creada con datos iniciales');
  return oid;
end $$;

-- ---------- Usuarios ----------
create or replace function app_private.create_auth_user(p_email text, p_password text, p_name text, p_platform_admin boolean default false)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := gen_random_uuid(); em text := lower(trim(p_email));
begin
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo electrónico inválido.'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'La contraseña debe tener al menos 8 caracteres.'; end if;
  if exists(select 1 from auth.users where lower(email) = em) then raise exception 'Ya existe un usuario con el correo %.', em; end if;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
      crypt(p_password, gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', p_name),
      now(), now(), '', '', '', '');
  insert into auth.identities(id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', uid::text, now(), now(), now());
  perform set_config('app.allow_post', 'on', true);
  insert into profiles(id, email, full_name, is_platform_admin) values (uid, em, p_name, p_platform_admin);
  perform set_config('app.allow_post', 'off', true);
  return uid;
end $$;

create or replace function app_private.assert_one_admin_left(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from organization_members where organization_id = p_org and role = 'admin' and active) then
    raise exception 'La empresa debe conservar al menos un administrador activo.';
  end if;
end $$;

create or replace function public.admin_create_user(p_org uuid, p_email text, p_password text, p_full_name text, p_role public.app_role)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  perform app_private.require_perm(p_org, 'users.manage');
  uid := app_private.create_auth_user(p_email, p_password, p_full_name, false);
  insert into organization_members(organization_id, user_id, role) values (p_org, uid, p_role);
  perform app_private.log_audit(p_org, 'create_user', 'organization_members', uid::text, 'Usuario creado con rol ' || p_role::text, null,
          jsonb_build_object('email', lower(trim(p_email)), 'role', p_role));
  return uid;
end $$;

create or replace function public.add_member_by_email(p_org uuid, p_email text, p_role public.app_role) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  perform app_private.require_perm(p_org, 'users.manage');
  select id into uid from profiles where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'No existe un usuario con ese correo. Créelo con "Nuevo usuario".'; end if;
  insert into organization_members(organization_id, user_id, role) values (p_org, uid, p_role)
  on conflict (organization_id, user_id) do update set role = excluded.role, active = true;
  perform app_private.log_audit(p_org, 'add_member', 'organization_members', uid::text, 'Rol ' || p_role::text);
end $$;

create or replace function public.set_member_role(p_org uuid, p_user uuid, p_role public.app_role) returns void
language plpgsql security definer set search_path = public as $$
declare old_role public.app_role;
begin
  perform app_private.require_perm(p_org, 'users.manage');
  select role into old_role from organization_members where organization_id = p_org and user_id = p_user;
  if old_role is null then raise exception 'El usuario no pertenece a la empresa.'; end if;
  update organization_members set role = p_role where organization_id = p_org and user_id = p_user;
  perform app_private.assert_one_admin_left(p_org);
  perform app_private.log_audit(p_org, 'set_role', 'organization_members', p_user::text, null,
          jsonb_build_object('role', old_role), jsonb_build_object('role', p_role));
end $$;

create or replace function public.set_member_active(p_org uuid, p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app_private.require_perm(p_org, 'users.manage');
  if p_user = auth.uid() and not p_active then raise exception 'No puede desactivarse a sí mismo.'; end if;
  update organization_members set active = p_active where organization_id = p_org and user_id = p_user;
  perform app_private.assert_one_admin_left(p_org);
  perform app_private.log_audit(p_org, case when p_active then 'activate_member' else 'deactivate_member' end,
          'organization_members', p_user::text);
end $$;

create or replace function public.admin_set_password(p_org uuid, p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform app_private.require_perm(p_org, 'users.manage');
  if not exists(select 1 from organization_members where organization_id = p_org and user_id = p_user) then
    raise exception 'El usuario no pertenece a la empresa.'; end if;
  if exists(select 1 from profiles where id = p_user and is_platform_admin) and not public.is_platform_admin() then
    raise exception 'No puede cambiar la contraseña del administrador general.'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'La contraseña debe tener al menos 8 caracteres.'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
  perform app_private.log_audit(p_org, 'reset_password', 'organization_members', p_user::text, 'Contraseña restablecida por un administrador');
end $$;

create or replace function public.set_role_permission(p_org uuid, p_role public.app_role, p_perm text, p_granted boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app_private.require_perm(p_org, 'users.manage');
  if not (p_perm = any(app_private.all_permissions())) then raise exception 'Permiso desconocido.'; end if;
  if p_role = 'admin' and p_perm in ('users.manage','data.view') and not p_granted then
    raise exception 'El rol Administrador debe conservar la gestión de usuarios y la consulta.'; end if;
  if p_granted then
    insert into role_permissions(organization_id, role, permission) values (p_org, p_role, p_perm) on conflict do nothing;
  else
    delete from role_permissions where organization_id = p_org and role = p_role and permission = p_perm;
  end if;
end $$;

-- ---------- Periodos contables ----------
create or replace function public.generate_periods(p_org uuid, p_year int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.has_perm(p_org, 'config.manage') or public.has_perm(p_org, 'periods.close')) then
    raise exception 'No tiene permiso para crear periodos.' using errcode = '42501'; end if;
  if p_year < 2000 or p_year > 2100 then raise exception 'Año inválido.'; end if;
  perform app_private.gen_periods(p_org, p_year);
  perform app_private.log_audit(p_org, 'generate_periods', 'accounting_periods', p_year::text);
end $$;

create or replace function public.close_period(p_period uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare per accounting_periods; n int := 0; c int; x record;
begin
  select * into per from accounting_periods where id = p_period for update;
  if per.id is null then raise exception 'Periodo inexistente.'; end if;
  perform app_private.require_perm(per.organization_id, 'periods.close');
  if per.status = 'closed' then raise exception 'El periodo ya está cerrado.'; end if;
  for x in select * from (values ('journal_entries','entry_date'),('purchase_invoices','issue_date'),('sales_invoices','issue_date'),
      ('supplier_payments','payment_date'),('customer_receipts','receipt_date'),('cash_movements','movement_date'),
      ('inventory_adjustments','adjustment_date')) v(t, d) loop
    execute format('select count(*) from public.%I where organization_id = $1 and %I between $2 and $3 and status in (''pending_approval'',''approved'')', x.t, x.d)
      into c using per.organization_id, per.start_date, per.end_date;
    n := n + c;
  end loop;
  if n > 0 then raise exception 'No se puede cerrar: hay % documento(s) pendientes de aprobación o de contabilización en el periodo.', n; end if;
  update accounting_periods set status = 'closed', closed_at = now(), closed_by = auth.uid() where id = p_period;
  insert into accounting_close_runs(organization_id, period_id, action, reason) values (per.organization_id, p_period, 'close', p_reason);
  perform app_private.log_audit(per.organization_id, 'close_period', 'accounting_periods', p_period::text, p_reason);
end $$;

create or replace function public.reopen_period(p_period uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare per accounting_periods;
begin
  select * into per from accounting_periods where id = p_period for update;
  if per.id is null then raise exception 'Periodo inexistente.'; end if;
  perform app_private.require_perm(per.organization_id, 'periods.reopen');
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Indique el motivo de la reapertura (mínimo 5 caracteres).'; end if;
  if per.status <> 'closed' then raise exception 'El periodo no está cerrado.'; end if;
  update accounting_periods set status = 'open', closed_at = null, closed_by = null where id = p_period;
  insert into accounting_close_runs(organization_id, period_id, action, reason) values (per.organization_id, p_period, 'reopen', p_reason);
  perform app_private.log_audit(per.organization_id, 'reopen_period', 'accounting_periods', p_period::text, p_reason);
end $$;

-- =====================================================================
-- PARTE 5: INVENTARIOS Y MOTOR DE CONTABILIZACIÓN
-- =====================================================================

create or replace function app_private.get_rule(p_org uuid, p_key text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare a uuid;
begin
  select account_id into a from accounting_rules where organization_id = p_org and rule_key = p_key;
  if a is null then
    raise exception 'Falta configurar la cuenta contable "%" en Configuración > Reglas contables.', p_key;
  end if;
  return a;
end $$;

create or replace function app_private.doc_table(p_type text) returns text language sql immutable as $$
  select case p_type
    when 'purchase_invoice' then 'purchase_invoices' when 'sales_invoice' then 'sales_invoices'
    when 'supplier_payment' then 'supplier_payments' when 'customer_receipt' then 'customer_receipts'
    when 'journal_entry' then 'journal_entries' when 'inventory_adjustment' then 'inventory_adjustments'
    when 'cash_movement' then 'cash_movements' when 'bank_reconciliation' then 'bank_reconciliations'
    else null end
$$;

-- ---------- Constructor de asientos ----------
create or replace function app_private.je_new(p_org uuid, p_date date, p_desc text, p_ref text, p_cur char(3), p_rate numeric,
  p_kind text, p_src_type text, p_src_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  insert into journal_entries(organization_id, entry_date, description, reference, currency_code, exchange_rate, entry_kind,
                              source_type, source_id, status, created_by)
  values (p_org, p_date, left(p_desc, 500), p_ref, p_cur, p_rate, p_kind, p_src_type, p_src_id, 'draft', auth.uid())
  returning journal_entries.id into id;
  return id;
end $$;

create or replace function app_private.je_line(p_je uuid, p_org uuid, p_acct uuid, p_act uuid, p_desc text,
  p_debit numeric, p_credit numeric, p_dbase numeric, p_cbase numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_dbase, 0) = 0 and coalesce(p_cbase, 0) = 0 then return; end if;
  insert into journal_entry_lines(organization_id, entry_id, account_id, activity_id, description, debit, credit, debit_base, credit_base)
  values (p_org, p_je, p_acct, p_act, left(p_desc, 300), coalesce(p_debit, 0), coalesce(p_credit, 0), coalesce(p_dbase, 0), coalesce(p_cbase, 0));
end $$;

create or replace function app_private.je_finalize(p_je uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e journal_entries; d numeric; c numeric; n int; bad int;
begin
  select * into e from journal_entries where id = p_je for update;
  perform app_private.assert_period_open(e.organization_id, e.entry_date);
  select coalesce(sum(debit_base), 0), coalesce(sum(credit_base), 0), count(*) into d, c, n from journal_entry_lines where entry_id = p_je;
  if n < 2 then raise exception 'El asiento debe tener al menos dos líneas.'; end if;
  if d <> c then raise exception 'El asiento no está cuadrado: débitos % ≠ créditos % (moneda base).', d, c; end if;
  if d = 0 then raise exception 'El asiento no tiene importes.'; end if;
  select count(*) into bad from journal_entry_lines l join accounts a on a.id = l.account_id
   where l.entry_id = p_je and (not a.is_postable or not a.active);
  if bad > 0 then raise exception 'El asiento usa cuentas de agrupación o inactivas.'; end if;
  update journal_entries set status = 'posted', entry_number = coalesce(entry_number, app_private.next_seq(e.organization_id, 'journal_entry')),
         total_debit_base = d, total_credit_base = c, posted_by = auth.uid(), posted_at = now()
   where id = p_je;
end $$;

create or replace function app_private.reverse_entry(p_je uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare e journal_entries; nid uuid; l record;
begin
  select * into e from journal_entries where id = p_je for update;
  if e.status <> 'posted' then raise exception 'Solo se pueden revertir asientos contabilizados.'; end if;
  if e.reversed_by_entry_id is not null then raise exception 'El asiento ya fue revertido.'; end if;
  nid := app_private.je_new(e.organization_id, current_date, 'Reversión: ' || e.description || coalesce(' — ' || p_reason, ''),
                            e.reference, e.currency_code, e.exchange_rate, 'reversal', null, null);
  update journal_entries set reverses_entry_id = p_je where id = nid;
  for l in select * from journal_entry_lines where entry_id = p_je order by line_no loop
    perform app_private.je_line(nid, e.organization_id, l.account_id, l.activity_id, 'Reversión: ' || coalesce(l.description, ''),
                                l.credit, l.debit, l.credit_base, l.debit_base);
  end loop;
  perform app_private.je_finalize(nid);
  update journal_entries set reversed_by_entry_id = nid where id = p_je;
  return nid;
end $$;

-- ---------- Inventarios ----------
create or replace function app_private.inv_receive(p_org uuid, p_product uuid, p_date date, p_qty numeric, p_cost numeric,
  p_type text, p_src_type text, p_src_id uuid, p_src_line uuid, p_je uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare prod products; mid uuid; method text;
begin
  select * into prod from products where id = p_product and organization_id = p_org for update;
  if prod.id is null then raise exception 'Producto inexistente.'; end if;
  if prod.product_type <> 'inventory' then raise exception 'El producto "%" no es de inventario.', prod.name; end if;
  if p_qty <= 0 then raise exception 'La cantidad debe ser positiva.'; end if;
  select valuation_method into method from inventory_settings where organization_id = p_org;
  insert into inventory_movements(organization_id, product_id, movement_date, movement_type, quantity, unit_cost, total_cost,
                                  source_type, source_id, source_line_id, journal_entry_id)
  values (p_org, p_product, p_date, p_type, p_qty, round(p_cost / p_qty, 6), p_cost, p_src_type, p_src_id, p_src_line, p_je)
  returning id into mid;
  if method = 'fifo' then
    insert into inventory_cost_layers(organization_id, product_id, movement_id, layer_date, qty_initial, qty_remaining, unit_cost, value_remaining)
    values (p_org, p_product, mid, p_date, p_qty, p_qty, round(p_cost / p_qty, 6), p_cost);
  end if;
  update products set qty_on_hand = prod.qty_on_hand + p_qty, inventory_value = prod.inventory_value + p_cost,
         avg_cost = case when prod.qty_on_hand + p_qty > 0 then round((prod.inventory_value + p_cost) / (prod.qty_on_hand + p_qty), 6) else prod.avg_cost end
   where id = p_product;
  return mid;
end $$;

create or replace function app_private.inv_issue(p_org uuid, p_product uuid, p_date date, p_qty numeric,
  p_type text, p_src_type text, p_src_id uuid, p_src_line uuid, p_je uuid) returns numeric
language plpgsql security definer set search_path = public as $$
declare prod products; s inventory_settings; cost numeric := 0; rem numeric; take numeric; c numeric; l record;
begin
  select * into prod from products where id = p_product and organization_id = p_org for update;
  if prod.id is null then raise exception 'Producto inexistente.'; end if;
  if prod.product_type <> 'inventory' then raise exception 'El producto "%" no es de inventario.', prod.name; end if;
  select * into s from inventory_settings where organization_id = p_org;
  if p_qty <= 0 then raise exception 'La cantidad debe ser positiva.'; end if;
  if prod.qty_on_hand < p_qty and not s.allow_negative_stock then
    raise exception 'Existencias insuficientes de "%": disponible %, requerido %.', prod.name, prod.qty_on_hand, p_qty;
  end if;
  if s.valuation_method = 'weighted_average' then
    if prod.qty_on_hand <= 0 then cost := round(p_qty * prod.avg_cost, 2);
    elsif p_qty >= prod.qty_on_hand then cost := prod.inventory_value + round((p_qty - prod.qty_on_hand) * prod.avg_cost, 2);
    else cost := round(prod.inventory_value * p_qty / prod.qty_on_hand, 2); end if;
  else
    rem := p_qty;
    for l in select * from inventory_cost_layers where product_id = p_product and qty_remaining > 0
             order by layer_date, seq for update loop
      take := least(rem, l.qty_remaining);
      c := case when take = l.qty_remaining then l.value_remaining else round(l.value_remaining * take / l.qty_remaining, 2) end;
      update inventory_cost_layers set qty_remaining = qty_remaining - take, value_remaining = value_remaining - c where id = l.id;
      cost := cost + c; rem := rem - take;
      exit when rem <= 0;
    end loop;
    if rem > 0 then cost := cost + round(rem * prod.avg_cost, 2); end if;
  end if;
  insert into inventory_movements(organization_id, product_id, movement_date, movement_type, quantity, unit_cost, total_cost,
                                  source_type, source_id, source_line_id, journal_entry_id)
  values (p_org, p_product, p_date, p_type, -p_qty, round(cost / p_qty, 6), -cost, p_src_type, p_src_id, p_src_line, p_je);
  update products set qty_on_hand = prod.qty_on_hand - p_qty, inventory_value = prod.inventory_value - cost,
         avg_cost = case when prod.qty_on_hand - p_qty > 0 then round((prod.inventory_value - cost) / (prod.qty_on_hand - p_qty), 6) else prod.avg_cost end
   where id = p_product;
  return cost;
end $$;

-- Deshace una entrada de inventario al costo original (devolución a proveedor / anulación)
create or replace function app_private.inv_unreceive(m inventory_movements, p_type text, p_je uuid) returns void
language plpgsql security definer set search_path = public as $$
declare prod products; s inventory_settings; lay inventory_cost_layers;
begin
  select * into prod from products where id = m.product_id for update;
  select * into s from inventory_settings where organization_id = m.organization_id;
  if prod.qty_on_hand < m.quantity or prod.inventory_value < m.total_cost then
    raise exception 'No se puede revertir: las existencias de "%" ya fueron utilizadas.', prod.name;
  end if;
  if s.valuation_method = 'fifo' then
    select * into lay from inventory_cost_layers where movement_id = m.id for update;
    if lay.id is not null then
      if lay.qty_remaining <> lay.qty_initial then
        raise exception 'No se puede revertir: parte de las existencias de "%" ya fue utilizada.', prod.name; end if;
      update inventory_cost_layers set qty_remaining = 0, value_remaining = 0 where id = lay.id;
    end if;
  end if;
  insert into inventory_movements(organization_id, product_id, movement_date, movement_type, quantity, unit_cost, total_cost,
                                  source_type, source_id, source_line_id, journal_entry_id)
  values (m.organization_id, m.product_id, current_date, p_type, -m.quantity, m.unit_cost, -m.total_cost, m.source_type, m.source_id, m.source_line_id, p_je);
  update products set qty_on_hand = prod.qty_on_hand - m.quantity, inventory_value = prod.inventory_value - m.total_cost,
         avg_cost = case when prod.qty_on_hand - m.quantity > 0 then round((prod.inventory_value - m.total_cost) / (prod.qty_on_hand - m.quantity), 6) else prod.avg_cost end
   where id = m.product_id;
end $$;


-- =====================================================================
-- PARTE 6: VALIDACIONES Y ASIENTOS AUTOMÁTICOS POR TIPO DE DOCUMENTO
-- =====================================================================

create or replace function app_private.validate_doc(p_type text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare org uuid; n int; d date; basecur char(3); cur char(3); rate numeric; tot numeric; amt numeric; party uuid;
        bank_id uuid; bank cash_bank_accounts; bank2 cash_bank_accounts; a record; inv record; ds numeric; cs numeric; mt text; cnt uuid;
begin
  if p_type in ('purchase_invoice','sales_invoice') then
    if p_type = 'purchase_invoice' then
      select organization_id, issue_date, currency_code, exchange_rate, total, supplier_id into org, d, cur, rate, tot, party from purchase_invoices where id = p_id;
      select count(*) into n from purchase_invoice_lines where invoice_id = p_id;
      if not exists(select 1 from suppliers where id = party and active) then raise exception 'El proveedor está inactivo.'; end if;
    else
      select organization_id, issue_date, currency_code, exchange_rate, total, customer_id into org, d, cur, rate, tot, party from sales_invoices where id = p_id;
      select count(*) into n from sales_invoice_lines where invoice_id = p_id;
      if not exists(select 1 from customers where id = party and active) then raise exception 'El cliente está inactivo.'; end if;
    end if;
    if n = 0 then raise exception 'El documento no tiene líneas.'; end if;
    if tot <= 0 then raise exception 'El total del documento debe ser mayor que cero.'; end if;
    select base_currency into basecur from organizations where id = org;
    if cur = basecur and rate <> 1 then raise exception 'En moneda base el tipo de cambio debe ser 1.'; end if;
    perform app_private.assert_period_open(org, d);
    if p_type = 'purchase_invoice' then
      select count(*) into n from purchase_invoice_lines l join tax_types t on t.id = l.tax_type_id
       where l.invoice_id = p_id and (not t.active or t.applies_to = 'sales' or (t.valid_from is not null and d < t.valid_from) or (t.valid_to is not null and d > t.valid_to));
    else
      select count(*) into n from sales_invoice_lines l join tax_types t on t.id = l.tax_type_id
       where l.invoice_id = p_id and (not t.active or t.applies_to = 'purchase' or (t.valid_from is not null and d < t.valid_from) or (t.valid_to is not null and d > t.valid_to));
    end if;
    if n > 0 then raise exception 'Hay impuestos inactivos, vencidos o no aplicables a este tipo de operación.'; end if;

  elsif p_type = 'supplier_payment' then
    select organization_id, payment_date, currency_code, exchange_rate, amount, supplier_id, cash_bank_account_id into org, d, cur, rate, amt, party, bank_id from supplier_payments where id = p_id;
    select * into bank from cash_bank_accounts where id = bank_id;
    if bank.currency_code <> cur then raise exception 'La moneda del pago debe coincidir con la de la cuenta de caja/banco.'; end if;
    select base_currency into basecur from organizations where id = org;
    if cur = basecur and rate <> 1 then raise exception 'En moneda base el tipo de cambio debe ser 1.'; end if;
    perform app_private.assert_period_open(org, d);
    select coalesce(sum(amount), 0) into tot from supplier_payment_allocations where payment_id = p_id;
    if tot <> amt then raise exception 'El total asignado a facturas (%) debe ser igual al importe del pago (%).', tot, amt; end if;
    for a in select al.amount, i.* from supplier_payment_allocations al join purchase_invoices i on i.id = al.invoice_id where al.payment_id = p_id loop
      if a.status <> 'posted' then raise exception 'La factura % no está contabilizada.', a.supplier_doc_number; end if;
      if a.supplier_id <> party then raise exception 'La factura % es de otro proveedor.', a.supplier_doc_number; end if;
      if a.currency_code <> cur then raise exception 'La factura % está en otra moneda.', a.supplier_doc_number; end if;
      if a.amount > a.total - a.paid_amount then raise exception 'La asignación supera el saldo pendiente de la factura % (saldo %).', a.supplier_doc_number, a.total - a.paid_amount; end if;
    end loop;

  elsif p_type = 'customer_receipt' then
    select organization_id, receipt_date, currency_code, exchange_rate, amount, customer_id, cash_bank_account_id into org, d, cur, rate, amt, party, bank_id from customer_receipts where id = p_id;
    select * into bank from cash_bank_accounts where id = bank_id;
    if bank.currency_code <> cur then raise exception 'La moneda del cobro debe coincidir con la de la cuenta de caja/banco.'; end if;
    select base_currency into basecur from organizations where id = org;
    if cur = basecur and rate <> 1 then raise exception 'En moneda base el tipo de cambio debe ser 1.'; end if;
    perform app_private.assert_period_open(org, d);
    select coalesce(sum(amount), 0) into tot from customer_receipt_allocations where receipt_id = p_id;
    if tot <> amt then raise exception 'El total asignado a facturas (%) debe ser igual al importe del cobro (%).', tot, amt; end if;
    for a in select al.amount, i.* from customer_receipt_allocations al join sales_invoices i on i.id = al.invoice_id where al.receipt_id = p_id loop
      if a.status <> 'posted' then raise exception 'La factura % no está contabilizada.', a.invoice_number; end if;
      if a.customer_id <> party then raise exception 'La factura % es de otro cliente.', a.invoice_number; end if;
      if a.currency_code <> cur then raise exception 'La factura % está en otra moneda.', a.invoice_number; end if;
      if a.amount > a.total - a.paid_amount then raise exception 'La asignación supera el saldo pendiente de la factura % (saldo %).', a.invoice_number, a.total - a.paid_amount; end if;
    end loop;

  elsif p_type = 'cash_movement' then
    select organization_id, movement_date, currency_code, exchange_rate, movement_type, cash_bank_account_id, counter_account_id
      into org, d, cur, rate, mt, bank_id, cnt from cash_movements where id = p_id;
    select * into bank from cash_bank_accounts where id = bank_id;
    if bank.currency_code <> cur then raise exception 'La moneda debe coincidir con la de la cuenta de caja/banco.'; end if;
    if mt = 'transfer' then
      select b.* into bank2 from cash_bank_accounts b join cash_movements m on m.to_cash_bank_account_id = b.id where m.id = p_id;
      if bank2.currency_code <> cur then raise exception 'La transferencia entre cuentas de distinta moneda no está disponible en esta versión.'; end if;
    end if;
    select base_currency into basecur from organizations where id = org;
    if cur = basecur and rate <> 1 then raise exception 'En moneda base el tipo de cambio debe ser 1.'; end if;
    perform app_private.assert_period_open(org, d);

  elsif p_type = 'inventory_adjustment' then
    select organization_id, adjustment_date into org, d from inventory_adjustments where id = p_id;
    select count(*) into n from inventory_adjustment_lines where adjustment_id = p_id;
    if n = 0 then raise exception 'El ajuste no tiene líneas.'; end if;
    perform app_private.assert_period_open(org, d);

  elsif p_type = 'journal_entry' then
    select organization_id, entry_date, currency_code, exchange_rate into org, d, cur, rate from journal_entries where id = p_id;
    select base_currency into basecur from organizations where id = org;
    if cur = basecur and rate <> 1 then raise exception 'En moneda base el tipo de cambio debe ser 1.'; end if;
    select coalesce(sum(debit_base), 0), coalesce(sum(credit_base), 0), count(*) into ds, cs, n from journal_entry_lines where entry_id = p_id;
    if n < 2 then raise exception 'El asiento debe tener al menos dos líneas.'; end if;
    if ds <> cs then raise exception 'El asiento no está cuadrado: débitos % ≠ créditos % (moneda base).', ds, cs; end if;
    if ds = 0 then raise exception 'El asiento no tiene importes.'; end if;
    perform app_private.assert_period_open(org, d);

  elsif p_type = 'bank_reconciliation' then
    select count(*) into n from bank_reconciliation_matches where reconciliation_id = p_id and status = 'active';
    if n = 0 then raise exception 'La conciliación no tiene coincidencias registradas.'; end if;
  end if;
end $$;

-- ---------- Compra ----------
create or replace function app_private.post_purchase_invoice(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare inv purchase_invoices; l record; tr tax_types; je uuid; rate numeric; sup text; acct uuid; cost numeric; cb numeric;
  landed numeric := 0; inv_pool numeric := 0; n_inv int := 0; i_inv int := 0; alloc numeric := 0; share numeric; line_base numeric;
  deb_sum numeric := 0; tax_b numeric; payable uuid;
begin
  select * into inv from purchase_invoices where id = p_id;
  perform app_private.assert_period_open(inv.organization_id, inv.issue_date);
  rate := inv.exchange_rate;
  select name into sup from suppliers where id = inv.supplier_id;
  payable := app_private.get_rule(inv.organization_id, 'purchase.payable');
  -- Pasada 1: costos a capitalizar
  for l in select * from purchase_invoice_lines where invoice_id = p_id loop
    cost := l.base_amount;
    if l.tax_type_id is not null then
      select * into tr from tax_types where id = l.tax_type_id;
      if tr.treatment = 'payable' then raise exception 'El impuesto % es de ventas y no puede usarse en compras.', tr.code; end if;
      if tr.treatment = 'cost' then cost := cost + l.tax_amount; end if;
    end if;
    cb := round(cost * rate, 2);
    if l.line_kind = 'landed_cost' then landed := landed + cb;
    elsif l.line_kind = 'inventory' then inv_pool := inv_pool + cb; n_inv := n_inv + 1; end if;
  end loop;
  if landed > 0 and inv_pool = 0 then raise exception 'Hay costos adicionales de adquisición pero ninguna línea de inventario donde distribuirlos.'; end if;

  je := app_private.je_new(inv.organization_id, inv.issue_date,
        'Compra ' || inv.doc_number || ' — ' || sup || ' (doc. ' || inv.supplier_doc_number || ')', inv.supplier_doc_number,
        inv.currency_code, rate, 'auto', 'purchase_invoice', p_id);

  for l in select pl.*, p.inventory_account_id as p_inv, p.expense_account_id as p_exp, p.name as p_name
           from purchase_invoice_lines pl left join products p on p.id = pl.product_id
           where pl.invoice_id = p_id order by pl.line_no loop
    cost := l.base_amount; tax_b := 0;
    if l.tax_type_id is not null then
      select * into tr from tax_types where id = l.tax_type_id;
      if tr.treatment = 'cost' then cost := cost + l.tax_amount;
      elsif l.tax_amount > 0 then
        tax_b := round(l.tax_amount * rate, 2);
        perform app_private.je_line(je, inv.organization_id, tr.account_id, l.activity_id, 'Impuesto ' || tr.code || ' — ' || coalesce(l.description, ''), l.tax_amount, 0, tax_b, 0);
        deb_sum := deb_sum + tax_b;
      end if;
    end if;
    cb := round(cost * rate, 2);
    if l.line_kind = 'inventory' then
      i_inv := i_inv + 1;
      if i_inv = n_inv then share := landed - alloc; else share := round(landed * cb / inv_pool, 2); alloc := alloc + share; end if;
      line_base := cb + share;
      acct := coalesce(l.p_inv, app_private.get_rule(inv.organization_id, 'inventory.asset'));
      perform app_private.je_line(je, inv.organization_id, acct, l.activity_id, 'Inventario: ' || coalesce(l.p_name, l.description, ''),
                                  round(line_base / rate, 2), 0, line_base, 0);
      deb_sum := deb_sum + line_base;
      perform app_private.inv_receive(inv.organization_id, l.product_id, inv.issue_date, l.quantity, line_base, 'purchase_in',
                                      'purchase_invoice', p_id, l.id, je);
    elsif l.line_kind = 'expense' then
      acct := coalesce(l.account_id, l.p_exp, app_private.get_rule(inv.organization_id, 'purchase.expense'));
      perform app_private.je_line(je, inv.organization_id, acct, l.activity_id, coalesce(l.description, l.p_name, 'Gasto'), cost, 0, cb, 0);
      deb_sum := deb_sum + cb;
    end if;
  end loop;
  perform app_private.je_line(je, inv.organization_id, payable, null, 'Cuenta por pagar — ' || sup || ' (' || inv.supplier_doc_number || ')',
                              0, inv.total, 0, deb_sum);
  perform app_private.je_finalize(je);
  update purchase_invoices set journal_entry_id = je, total_base = deb_sum where id = p_id;
  return je;
end $$;

-- ---------- Venta ----------
create or replace function app_private.post_sales_invoice(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare inv sales_invoices; l record; tr tax_types; je uuid; rate numeric; cust text; acct uuid; nb numeric; tb numeric;
  cred_sum numeric := 0; cogs numeric; recv uuid;
begin
  select * into inv from sales_invoices where id = p_id;
  perform app_private.assert_period_open(inv.organization_id, inv.issue_date);
  rate := inv.exchange_rate;
  select name into cust from customers where id = inv.customer_id;
  recv := app_private.get_rule(inv.organization_id, 'sales.receivable');
  je := app_private.je_new(inv.organization_id, inv.issue_date, 'Venta ' || inv.doc_number || ' — ' || cust || ' (fact. ' || inv.invoice_number || ')',
        inv.invoice_number, inv.currency_code, rate, 'auto', 'sales_invoice', p_id);
  for l in select sl.*, p.revenue_account_id as p_rev, p.inventory_account_id as p_inv, p.cogs_account_id as p_cogs,
                  p.name as p_name, p.product_type as p_type
           from sales_invoice_lines sl left join products p on p.id = sl.product_id
           where sl.invoice_id = p_id order by sl.line_no loop
    nb := round(l.base_amount * rate, 2);
    acct := coalesce(l.account_id, l.p_rev, app_private.get_rule(inv.organization_id, 'sales.revenue'));
    perform app_private.je_line(je, inv.organization_id, acct, l.activity_id, coalesce(l.description, l.p_name, 'Venta'), 0, l.base_amount, 0, nb);
    cred_sum := cred_sum + nb;
    if l.tax_type_id is not null and l.tax_amount > 0 then
      select * into tr from tax_types where id = l.tax_type_id;
      if tr.treatment <> 'payable' then raise exception 'El impuesto % no puede usarse en ventas.', tr.code; end if;
      tb := round(l.tax_amount * rate, 2);
      perform app_private.je_line(je, inv.organization_id, tr.account_id, l.activity_id, 'Impuesto ' || tr.code, 0, l.tax_amount, 0, tb);
      cred_sum := cred_sum + tb;
    end if;
    if l.product_id is not null and l.p_type = 'inventory' then
      cogs := app_private.inv_issue(inv.organization_id, l.product_id, inv.issue_date, l.quantity, 'sale_out', 'sales_invoice', p_id, l.id, je);
      perform app_private.je_line(je, inv.organization_id, coalesce(l.p_cogs, app_private.get_rule(inv.organization_id, 'sales.cogs')), l.activity_id,
                                  'Costo de ventas: ' || l.p_name, round(cogs / rate, 2), 0, cogs, 0);
      perform app_private.je_line(je, inv.organization_id, coalesce(l.p_inv, app_private.get_rule(inv.organization_id, 'inventory.asset')), l.activity_id,
                                  'Salida de inventario: ' || l.p_name, 0, round(cogs / rate, 2), 0, cogs);
    end if;
  end loop;
  perform app_private.je_line(je, inv.organization_id, recv, null, 'Cuenta por cobrar — ' || cust || ' (' || inv.invoice_number || ')', inv.total, 0, cred_sum, 0);
  perform app_private.je_finalize(je);
  update sales_invoices set journal_entry_id = je, total_base = cred_sum where id = p_id;
  return je;
end $$;

-- ---------- Pago a proveedor ----------
create or replace function app_private.post_supplier_payment(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare pay supplier_payments; bank cash_bank_accounts; a record; inv purchase_invoices; je uuid; carry numeric; csum numeric := 0;
  cash_b numeric; diff numeric; payable uuid; sup text;
begin
  select * into pay from supplier_payments where id = p_id;
  perform app_private.assert_period_open(pay.organization_id, pay.payment_date);
  select * into bank from cash_bank_accounts where id = pay.cash_bank_account_id;
  select name into sup from suppliers where id = pay.supplier_id;
  payable := app_private.get_rule(pay.organization_id, 'purchase.payable');
  je := app_private.je_new(pay.organization_id, pay.payment_date, 'Pago ' || pay.doc_number || ' — ' || sup, pay.reference,
        pay.currency_code, pay.exchange_rate, 'auto', 'supplier_payment', p_id);
  for a in select * from supplier_payment_allocations where payment_id = p_id order by id loop
    select * into inv from purchase_invoices where id = a.invoice_id for update;
    if inv.status <> 'posted' or inv.paid_amount + a.amount > inv.total then
      raise exception 'La asignación supera el saldo pendiente de la factura % (saldo %).', inv.supplier_doc_number, inv.total - inv.paid_amount;
    end if;
    if inv.paid_amount + a.amount = inv.total then carry := inv.total_base - inv.paid_base_carried;
    else carry := round(a.amount * inv.exchange_rate, 2); end if;
    update purchase_invoices set paid_amount = paid_amount + a.amount, paid_base_carried = paid_base_carried + carry where id = inv.id;
    update supplier_payment_allocations set carried_base = carry where id = a.id;
    perform app_private.je_line(je, pay.organization_id, payable, null, 'Pago factura ' || inv.supplier_doc_number, a.amount, 0, carry, 0);
    csum := csum + carry;
  end loop;
  cash_b := round(pay.amount * pay.exchange_rate, 2);
  diff := cash_b - csum;
  if diff > 0 then perform app_private.je_line(je, pay.organization_id, app_private.get_rule(pay.organization_id, 'fx.loss'), null, 'Diferencia de cambio', diff, 0, diff, 0);
  elsif diff < 0 then perform app_private.je_line(je, pay.organization_id, app_private.get_rule(pay.organization_id, 'fx.gain'), null, 'Diferencia de cambio', 0, -diff, 0, -diff); end if;
  perform app_private.je_line(je, pay.organization_id, bank.account_id, null, 'Pago desde ' || bank.name, 0, pay.amount, 0, cash_b);
  perform app_private.je_finalize(je);
  update supplier_payments set journal_entry_id = je where id = p_id;
  return je;
end $$;

-- ---------- Cobro de cliente ----------
create or replace function app_private.post_customer_receipt(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare rec customer_receipts; bank cash_bank_accounts; a record; inv sales_invoices; je uuid; carry numeric; csum numeric := 0;
  cash_b numeric; diff numeric; recv uuid; cust text;
begin
  select * into rec from customer_receipts where id = p_id;
  perform app_private.assert_period_open(rec.organization_id, rec.receipt_date);
  select * into bank from cash_bank_accounts where id = rec.cash_bank_account_id;
  select name into cust from customers where id = rec.customer_id;
  recv := app_private.get_rule(rec.organization_id, 'sales.receivable');
  je := app_private.je_new(rec.organization_id, rec.receipt_date, 'Cobro ' || rec.doc_number || ' — ' || cust, rec.reference,
        rec.currency_code, rec.exchange_rate, 'auto', 'customer_receipt', p_id);
  for a in select * from customer_receipt_allocations where receipt_id = p_id order by id loop
    select * into inv from sales_invoices where id = a.invoice_id for update;
    if inv.status <> 'posted' or inv.paid_amount + a.amount > inv.total then
      raise exception 'La asignación supera el saldo pendiente de la factura % (saldo %).', inv.invoice_number, inv.total - inv.paid_amount;
    end if;
    if inv.paid_amount + a.amount = inv.total then carry := inv.total_base - inv.paid_base_carried;
    else carry := round(a.amount * inv.exchange_rate, 2); end if;
    update sales_invoices set paid_amount = paid_amount + a.amount, paid_base_carried = paid_base_carried + carry where id = inv.id;
    update customer_receipt_allocations set carried_base = carry where id = a.id;
    perform app_private.je_line(je, rec.organization_id, recv, null, 'Cobro factura ' || inv.invoice_number, 0, a.amount, 0, carry);
    csum := csum + carry;
  end loop;
  cash_b := round(rec.amount * rec.exchange_rate, 2);
  diff := cash_b - csum;
  if diff > 0 then perform app_private.je_line(je, rec.organization_id, app_private.get_rule(rec.organization_id, 'fx.gain'), null, 'Diferencia de cambio', 0, diff, 0, diff);
  elsif diff < 0 then perform app_private.je_line(je, rec.organization_id, app_private.get_rule(rec.organization_id, 'fx.loss'), null, 'Diferencia de cambio', -diff, 0, -diff, 0); end if;
  perform app_private.je_line(je, rec.organization_id, bank.account_id, null, 'Cobro en ' || bank.name, rec.amount, 0, cash_b, 0);
  perform app_private.je_finalize(je);
  update customer_receipts set journal_entry_id = je where id = p_id;
  return je;
end $$;

-- ---------- Movimiento de caja/banco ----------
create or replace function app_private.post_cash_movement(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare m cash_movements; b1 cash_bank_accounts; b2 cash_bank_accounts; je uuid; base numeric; txt text;
begin
  select * into m from cash_movements where id = p_id;
  perform app_private.assert_period_open(m.organization_id, m.movement_date);
  select * into b1 from cash_bank_accounts where id = m.cash_bank_account_id;
  base := round(m.amount * m.exchange_rate, 2);
  txt := coalesce(m.description, case m.movement_type when 'income' then 'Ingreso' when 'expense' then 'Egreso' else 'Transferencia' end);
  je := app_private.je_new(m.organization_id, m.movement_date, m.doc_number || ' — ' || txt, m.reference, m.currency_code, m.exchange_rate,
        'auto', 'cash_movement', p_id);
  if m.movement_type = 'income' then
    perform app_private.je_line(je, m.organization_id, b1.account_id, null, txt, m.amount, 0, base, 0);
    perform app_private.je_line(je, m.organization_id, m.counter_account_id, m.activity_id, txt, 0, m.amount, 0, base);
  elsif m.movement_type = 'expense' then
    perform app_private.je_line(je, m.organization_id, m.counter_account_id, m.activity_id, txt, m.amount, 0, base, 0);
    perform app_private.je_line(je, m.organization_id, b1.account_id, null, txt, 0, m.amount, 0, base);
  else
    select * into b2 from cash_bank_accounts where id = m.to_cash_bank_account_id;
    perform app_private.je_line(je, m.organization_id, b2.account_id, null, 'Transferencia desde ' || b1.name, m.amount, 0, base, 0);
    perform app_private.je_line(je, m.organization_id, b1.account_id, null, 'Transferencia hacia ' || b2.name, 0, m.amount, 0, base);
  end if;
  perform app_private.je_finalize(je);
  update cash_movements set journal_entry_id = je where id = p_id;
  return je;
end $$;

-- ---------- Ajuste de inventario ----------
create or replace function app_private.post_inventory_adjustment(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare adj inventory_adjustments; l record; je uuid; adj_acct uuid; cost numeric; inv_acct uuid; base_cur char(3);
begin
  select * into adj from inventory_adjustments where id = p_id;
  perform app_private.assert_period_open(adj.organization_id, adj.adjustment_date);
  select base_currency into base_cur from organizations where id = adj.organization_id;
  adj_acct := app_private.get_rule(adj.organization_id, 'inventory.adjustment');
  je := app_private.je_new(adj.organization_id, adj.adjustment_date, 'Ajuste de inventario ' || adj.doc_number || ' — ' || adj.reason,
        adj.doc_number, base_cur, 1, 'auto', 'inventory_adjustment', p_id);
  for l in select al.*, p.name as p_name, p.inventory_account_id as p_inv from inventory_adjustment_lines al
           join products p on p.id = al.product_id where al.adjustment_id = p_id order by al.line_no loop
    inv_acct := coalesce(l.p_inv, app_private.get_rule(adj.organization_id, 'inventory.asset'));
    if l.quantity_delta > 0 then
      cost := round(l.quantity_delta * l.unit_cost, 2);
      perform app_private.inv_receive(adj.organization_id, l.product_id, adj.adjustment_date, l.quantity_delta, cost, 'adjust_in', 'inventory_adjustment', p_id, l.id, je);
      perform app_private.je_line(je, adj.organization_id, inv_acct, l.activity_id, 'Ajuste (+) ' || l.p_name, cost, 0, cost, 0);
      perform app_private.je_line(je, adj.organization_id, adj_acct, l.activity_id, 'Ajuste (+) ' || l.p_name, 0, cost, 0, cost);
    else
      cost := app_private.inv_issue(adj.organization_id, l.product_id, adj.adjustment_date, -l.quantity_delta, 'adjust_out', 'inventory_adjustment', p_id, l.id, je);
      perform app_private.je_line(je, adj.organization_id, adj_acct, l.activity_id, 'Ajuste (-) ' || l.p_name, cost, 0, cost, 0);
      perform app_private.je_line(je, adj.organization_id, inv_acct, l.activity_id, 'Ajuste (-) ' || l.p_name, 0, cost, 0, cost);
    end if;
  end loop;
  perform app_private.je_finalize(je);
  update inventory_adjustments set journal_entry_id = je where id = p_id;
  return je;
end $$;

-- =====================================================================
-- PARTE 7: FLUJO DE APROBACIÓN, CONTABILIZACIÓN, REVERSIONES Y BANCOS
-- =====================================================================

create or replace function app_private.doc_label(p_type text, p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare r text;
begin
  if p_type = 'purchase_invoice' then
    select doc_number || ' · ' || supplier_doc_number || ' · ' || currency_code || ' ' || total into r from purchase_invoices where id = p_id;
  elsif p_type = 'sales_invoice' then
    select doc_number || ' · ' || invoice_number || ' · ' || currency_code || ' ' || total into r from sales_invoices where id = p_id;
  elsif p_type = 'supplier_payment' then
    select doc_number || ' · ' || currency_code || ' ' || amount into r from supplier_payments where id = p_id;
  elsif p_type = 'customer_receipt' then
    select doc_number || ' · ' || currency_code || ' ' || amount into r from customer_receipts where id = p_id;
  elsif p_type = 'journal_entry' then
    select coalesce('Asiento ' || entry_number, 'Asiento manual') || ' · ' || left(description, 60) into r from journal_entries where id = p_id;
  elsif p_type = 'inventory_adjustment' then
    select doc_number || ' · ' || left(reason, 60) into r from inventory_adjustments where id = p_id;
  elsif p_type = 'cash_movement' then
    select doc_number || ' · ' || movement_type || ' ' || currency_code || ' ' || amount into r from cash_movements where id = p_id;
  elsif p_type = 'bank_reconciliation' then
    select doc_number || ' · ' || period_from || ' a ' || period_to into r from bank_reconciliations where id = p_id;
  end if;
  return r;
end $$;

create or replace function app_private.set_doc_status(p_tbl text, p_id uuid, p_status public.doc_status, p_extra text default '') returns void
language plpgsql security definer set search_path = public as $$
declare prev text := coalesce(current_setting('app.allow_post', true), 'off');
begin
  perform set_config('app.allow_post', 'on', true);
  execute format('update public.%I set status = $2 %s where id = $1', p_tbl, p_extra) using p_id, p_status;
  perform set_config('app.allow_post', prev, true);
end $$;

create or replace function app_private.hist(p_org uuid, p_type text, p_id uuid, p_req uuid, p_action text,
  p_from text, p_to text, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into approval_history(organization_id, doc_type, doc_id, request_id, action, from_status, to_status, user_id, comment)
  values (p_org, p_type, p_id, p_req, p_action, p_from, p_to, auth.uid(), p_comment);
end $$;

-- Cargar documento bloqueado: devuelve org, estado y creador
create or replace function app_private.lock_doc(p_type text, p_id uuid, out o_tbl text, out o_org uuid, out o_status public.doc_status, out o_creator uuid)
language plpgsql security definer set search_path = public as $$
begin
  o_tbl := app_private.doc_table(p_type);
  if o_tbl is null then raise exception 'Tipo de documento desconocido: %', p_type; end if;
  execute format('select organization_id, status, created_by from public.%I where id = $1 for update', o_tbl) into o_org, o_status, o_creator using p_id;
  if o_org is null then raise exception 'Documento inexistente.'; end if;
end $$;

create or replace function public.submit_document(p_type text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; org uuid; st public.doc_status; cr uuid; req int; selfok boolean; rid uuid;
begin
  select * into tbl, org, st, cr from app_private.lock_doc(p_type, p_id);
  perform app_private.require_perm(org, 'documents.submit');
  if st not in ('draft','rejected') then raise exception 'Solo los documentos en borrador o rechazados pueden enviarse a aprobación.'; end if;
  perform app_private.recalc_totals(tbl, p_id);
  perform app_private.validate_doc(p_type, p_id);
  select required_approvals, allow_self_approval into req, selfok from approval_workflows where organization_id = org and doc_type = p_type and active;
  req := coalesce(req, 1); selfok := coalesce(selfok, false);
  perform app_private.set_doc_status(tbl, p_id, 'pending_approval', ', submitted_at = now(), rejection_reason = null');
  insert into approval_requests(organization_id, doc_type, doc_id, doc_label, required_approvals, allow_self_approval, submitted_by)
  values (org, p_type, p_id, app_private.doc_label(p_type, p_id), req, selfok, auth.uid()) returning id into rid;
  perform app_private.hist(org, p_type, p_id, rid, 'submitted', st::text, 'pending_approval', null);
  perform app_private.log_audit(org, 'submit', p_type, p_id::text, 'Enviado a aprobación');
end $$;

create or replace function public.approve_document(p_type text, p_id uuid, p_comment text default null) returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; org uuid; st public.doc_status; cr uuid; rq approval_requests; n int;
begin
  select * into tbl, org, st, cr from app_private.lock_doc(p_type, p_id);
  perform app_private.require_perm(org, 'documents.approve');
  if st <> 'pending_approval' then raise exception 'El documento no está pendiente de aprobación.'; end if;
  select * into rq from approval_requests where doc_type = p_type and doc_id = p_id and status = 'pending' for update;
  if rq.id is null then raise exception 'No hay una solicitud de aprobación activa.'; end if;
  if not rq.allow_self_approval and (auth.uid() = cr or auth.uid() = rq.submitted_by) then
    raise exception 'Segregación de funciones: no puede aprobar un documento que usted mismo registró o envió.';
  end if;
  if exists(select 1 from approval_steps where request_id = rq.id and approver_id = auth.uid()) then
    raise exception 'Usted ya registró su decisión sobre este documento.'; end if;
  insert into approval_steps(organization_id, request_id, approver_id, decision, comment) values (org, rq.id, auth.uid(), 'approved', p_comment);
  select count(*) into n from approval_steps where request_id = rq.id and decision = 'approved';
  perform app_private.hist(org, p_type, p_id, rq.id, 'approved_step', st::text, st::text, p_comment);
  if n >= rq.required_approvals then
    update approval_requests set status = 'approved', resolved_at = now() where id = rq.id;
    perform app_private.set_doc_status(tbl, p_id, 'approved', ', approved_at = now()');
    perform app_private.hist(org, p_type, p_id, rq.id, 'approved', st::text, 'approved', 'Aprobación completa');
    perform app_private.log_audit(org, 'approve', p_type, p_id::text, p_comment);
  end if;
end $$;

create or replace function public.reject_document(p_type text, p_id uuid, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; org uuid; st public.doc_status; cr uuid; rq approval_requests;
begin
  select * into tbl, org, st, cr from app_private.lock_doc(p_type, p_id);
  perform app_private.require_perm(org, 'documents.approve');
  if st <> 'pending_approval' then raise exception 'El documento no está pendiente de aprobación.'; end if;
  if length(trim(coalesce(p_comment, ''))) < 3 then raise exception 'Indique el motivo del rechazo.'; end if;
  select * into rq from approval_requests where doc_type = p_type and doc_id = p_id and status = 'pending' for update;
  insert into approval_steps(organization_id, request_id, approver_id, decision, comment) values (org, rq.id, auth.uid(), 'rejected', p_comment)
    on conflict (request_id, approver_id) do update set decision = 'rejected', comment = excluded.comment, decided_at = now();
  update approval_requests set status = 'rejected', resolved_at = now() where id = rq.id;
  perform app_private.set_doc_status(tbl, p_id, 'rejected', format(', rejection_reason = %L', p_comment));
  perform app_private.hist(org, p_type, p_id, rq.id, 'rejected', st::text, 'rejected', p_comment);
  perform app_private.log_audit(org, 'reject', p_type, p_id::text, p_comment);
end $$;

-- Devolver a borrador: invalida las aprobaciones (necesario antes de editar un documento aprobado)
create or replace function public.return_to_draft(p_type text, p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare tbl text; org uuid; st public.doc_status; cr uuid;
begin
  select * into tbl, org, st, cr from app_private.lock_doc(p_type, p_id);
  if not (public.has_perm(org, 'documents.approve') or (cr = auth.uid() and public.has_perm(org, 'documents.submit'))) then
    raise exception 'No tiene permiso para devolver este documento a borrador.' using errcode = '42501'; end if;
  if st not in ('pending_approval','approved','rejected') then raise exception 'El documento no puede devolverse a borrador desde el estado "%".', st; end if;
  update approval_requests set status = 'cancelled', resolved_at = now() where doc_type = p_type and doc_id = p_id and status in ('pending','approved');
  perform app_private.set_doc_status(tbl, p_id, 'draft', ', approved_at = null, submitted_at = null');
  perform app_private.hist(org, p_type, p_id, null, 'returned_to_draft', st::text, 'draft', p_reason);
  perform app_private.log_audit(org, 'return_to_draft', p_type, p_id::text, p_reason);
end $$;

create or replace function public.post_document(p_type text, p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare tbl text; org uuid; st public.doc_status; cr uuid; je uuid;
begin
  select * into tbl, org, st, cr from app_private.lock_doc(p_type, p_id);
  perform app_private.require_perm(org, 'documents.post');
  if st = 'posted' then   -- idempotente: no genera nada nuevo
    if p_type = 'journal_entry' then return p_id; end if;
    if p_type = 'bank_reconciliation' then return null; end if;
    execute format('select journal_entry_id from public.%I where id = $1', tbl) into je using p_id;
    return je;
  end if;
  if st <> 'approved' then raise exception 'El documento debe estar aprobado antes de contabilizarse (estado actual: %).', st; end if;
  if not exists(select 1 from approval_requests where doc_type = p_type and doc_id = p_id and status = 'approved') then
    raise exception 'No existe una aprobación completa para este documento.'; end if;
  perform set_config('app.allow_post', 'on', true);
  perform app_private.validate_doc(p_type, p_id);
  if p_type = 'purchase_invoice' then je := app_private.post_purchase_invoice(p_id);
  elsif p_type = 'sales_invoice' then je := app_private.post_sales_invoice(p_id);
  elsif p_type = 'supplier_payment' then je := app_private.post_supplier_payment(p_id);
  elsif p_type = 'customer_receipt' then je := app_private.post_customer_receipt(p_id);
  elsif p_type = 'cash_movement' then je := app_private.post_cash_movement(p_id);
  elsif p_type = 'inventory_adjustment' then je := app_private.post_inventory_adjustment(p_id);
  elsif p_type = 'journal_entry' then
    perform app_private.je_finalize(p_id); je := p_id;
  elsif p_type = 'bank_reconciliation' then je := null;
  end if;
  execute format('update public.%I set status = ''posted'', posted_by = auth.uid(), posted_at = now() where id = $1', tbl) using p_id;
  perform set_config('app.allow_post', 'off', true);
  perform app_private.hist(org, p_type, p_id, null, 'posted', 'approved', 'posted', null);
  perform app_private.log_audit(org, 'post', p_type, p_id::text, null, null, jsonb_build_object('journal_entry_id', je));
  return je;
end $$;

create or replace function public.reverse_document(p_type text, p_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare tbl text; org uuid; st public.doc_status; cr uuid; je uuid; rev uuid; m inventory_movements; a record; e journal_entries;
begin
  select * into tbl, org, st, cr from app_private.lock_doc(p_type, p_id);
  perform app_private.require_perm(org, 'documents.reverse');
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Indique el motivo (mínimo 5 caracteres).'; end if;
  if st <> 'posted' then raise exception 'Solo se pueden revertir o anular documentos contabilizados.'; end if;
  perform set_config('app.allow_post', 'on', true);
  if p_type = 'journal_entry' then
    select * into e from journal_entries where id = p_id;
    if e.source_type is not null or e.entry_kind <> 'manual' then
      raise exception 'Este asiento fue generado por otro documento: anule el documento de origen.'; end if;
    rev := app_private.reverse_entry(p_id, p_reason);
  elsif p_type = 'bank_reconciliation' then
    update bank_reconciliation_matches set status = 'undone', undone_by = auth.uid(), undone_at = now(), undone_reason = p_reason
     where reconciliation_id = p_id and status = 'active';
    perform app_private.refresh_statement_lines(null, p_id);
    perform app_private.set_doc_status(tbl, p_id, 'voided');
  else
    execute format('select journal_entry_id from public.%I where id = $1', tbl) into je using p_id;
    if p_type = 'purchase_invoice' and (exists(select 1 from supplier_payment_allocations al join supplier_payments p on p.id = al.payment_id where al.invoice_id = p_id and p.status <> 'voided')) then
      raise exception 'La factura tiene pagos asociados. Anule primero los pagos.'; end if;
    if p_type = 'sales_invoice' and (exists(select 1 from customer_receipt_allocations al join customer_receipts p on p.id = al.receipt_id where al.invoice_id = p_id and p.status <> 'voided')) then
      raise exception 'La factura tiene cobros asociados. Anule primero los cobros.'; end if;
    rev := app_private.reverse_entry(je, p_reason);
    -- inventario: contramovimientos al costo original
    for m in select * from inventory_movements where source_type = p_type and source_id = p_id and movement_type not like '%return%' order by created_at loop
      if m.quantity > 0 then
        perform app_private.inv_unreceive(m, case p_type when 'purchase_invoice' then 'purchase_return_out' else 'adjust_out' end, rev);
      else
        perform app_private.inv_receive(m.organization_id, m.product_id, current_date, -m.quantity, -m.total_cost,
                case p_type when 'sales_invoice' then 'sale_return_in' else 'adjust_in' end, p_type, p_id, m.source_line_id, rev);
      end if;
    end loop;
    if p_type = 'supplier_payment' then
      for a in select * from supplier_payment_allocations where payment_id = p_id loop
        update purchase_invoices set paid_amount = paid_amount - a.amount, paid_base_carried = paid_base_carried - coalesce(a.carried_base, 0) where id = a.invoice_id;
      end loop;
    elsif p_type = 'customer_receipt' then
      for a in select * from customer_receipt_allocations where receipt_id = p_id loop
        update sales_invoices set paid_amount = paid_amount - a.amount, paid_base_carried = paid_base_carried - coalesce(a.carried_base, 0) where id = a.invoice_id;
      end loop;
    end if;
    perform app_private.set_doc_status(tbl, p_id, 'voided');
  end if;
  perform set_config('app.allow_post', 'off', true);
  perform app_private.hist(org, p_type, p_id, null, 'reversed', 'posted', case when p_type = 'journal_entry' then 'posted' else 'voided' end, p_reason);
  perform app_private.log_audit(org, 'reverse', p_type, p_id::text, p_reason, null, jsonb_build_object('reversal_entry_id', rev));
  return rev;
end $$;

-- ---------- Bancos ----------
create or replace function app_private.refresh_statement_lines(p_line uuid, p_recon uuid) returns void
language plpgsql security definer set search_path = public as $$
declare prev text := coalesce(current_setting('app.allow_post', true), 'off');
begin
  perform set_config('app.allow_post', 'on', true);
  update bank_statement_lines l set
    matched_amount = coalesce(x.s, 0),
    match_status = case when l.match_status = 'ignored' then 'ignored'
                        when coalesce(x.s, 0) = 0 then 'unmatched'
                        when coalesce(x.s, 0) >= abs(l.credit - l.debit) then 'matched' else 'partial' end
  from (select l2.id, (select sum(m.amount) from bank_reconciliation_matches m where m.statement_line_id = l2.id and m.status = 'active') s
        from bank_statement_lines l2
        where l2.id = p_line or l2.id in (select statement_line_id from bank_reconciliation_matches where reconciliation_id = p_recon)) x
  where l.id = x.id;
  perform set_config('app.allow_post', prev, true);
end $$;

create or replace function public.import_bank_statement(p_org uuid, p_account uuid, p_file_name text, p_file_hash text,
  p_mapping jsonb, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare acc cash_bank_accounts; imp uuid; total int; ins int; pf date; pt date;
begin
  perform app_private.require_perm(p_org, 'bank.import');
  select * into acc from cash_bank_accounts where id = p_account and organization_id = p_org;
  if acc.id is null then raise exception 'Cuenta bancaria inexistente.'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'El archivo no contiene movimientos.'; end if;
  if jsonb_array_length(p_lines) > 20000 then raise exception 'El archivo supera el máximo de 20.000 movimientos.'; end if;
  if exists(select 1 from bank_statement_imports where cash_bank_account_id = p_account and file_hash = p_file_hash) then
    raise exception 'Este archivo ya fue importado anteriormente para esta cuenta.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) e where (e->>'line_date') is null or (e->>'line_date') !~ '^\d{4}-\d{2}-\d{2}$'
            or coalesce((e->>'debit')::numeric, 0) < 0 or coalesce((e->>'credit')::numeric, 0) < 0) then
    raise exception 'Hay filas con fecha inválida o importes negativos. Revise la correspondencia de columnas.'; end if;
  select min((e->>'line_date')::date), max((e->>'line_date')::date), count(*) into pf, pt, total from jsonb_array_elements(p_lines) e;
  insert into bank_statement_imports(organization_id, cash_bank_account_id, file_name, file_hash, period_from, period_to, currency_code, line_count, column_mapping)
  values (p_org, p_account, left(p_file_name, 255), p_file_hash, pf, pt, acc.currency_code, total, p_mapping) returning id into imp;
  with src as (
    select (e->>'line_date')::date line_date, nullif(e->>'value_date','')::date value_date, nullif(e->>'description','') description,
           nullif(e->>'reference','') reference, nullif(e->>'external_id','') external_id,
           coalesce((e->>'debit')::numeric, 0) debit, coalesce((e->>'credit')::numeric, 0) credit, nullif(e->>'balance','')::numeric balance
    from jsonb_array_elements(p_lines) e),
  keyed as (
    select *, md5(coalesce(external_id, line_date::text || '|' || debit || '|' || credit || '|' || coalesce(reference,'') || '|' || coalesce(description,''))) k from src),
  numbered as (select *, k || '#' || row_number() over (partition by k) dk from keyed),
  ins_rows as (
    insert into bank_statement_lines(organization_id, import_id, cash_bank_account_id, line_date, value_date, description, reference, external_id, debit, credit, balance, dedupe_key)
    select p_org, imp, p_account, line_date, value_date, left(description, 500), left(reference, 200), left(external_id, 200), debit, credit, balance, dk from numbered
    on conflict (cash_bank_account_id, dedupe_key) do nothing returning 1)
  select count(*) into ins from ins_rows;
  update bank_statement_imports set duplicate_count = total - ins where id = imp;
  perform app_private.log_audit(p_org, 'import_bank_statement', 'bank_statement_imports', imp::text, p_file_name,
          null, jsonb_build_object('lines', total, 'inserted', ins, 'duplicates', total - ins));
  return jsonb_build_object('import_id', imp, 'inserted', ins, 'duplicates', total - ins);
end $$;

create or replace function public.bank_match(p_recon uuid, p_stmt uuid, p_jline uuid, p_amount numeric, p_type text default 'manual') returns uuid
language plpgsql security definer set search_path = public as $$
declare r bank_reconciliations; sl bank_statement_lines; jl journal_entry_lines; je journal_entries; acc cash_bank_accounts;
  s_signed numeric; j_signed numeric; s_used numeric; j_used numeric; mid uuid;
begin
  select * into r from bank_reconciliations where id = p_recon for update;
  if r.id is null then raise exception 'Conciliación inexistente.'; end if;
  perform app_private.require_perm(r.organization_id, 'bank.reconcile');
  if r.status not in ('draft','rejected') then raise exception 'La conciliación no es editable en estado "%".', r.status; end if;
  select * into acc from cash_bank_accounts where id = r.cash_bank_account_id;
  select * into sl from bank_statement_lines where id = p_stmt for update;
  select * into jl from journal_entry_lines where id = p_jline for update;
  if sl.cash_bank_account_id <> r.cash_bank_account_id then raise exception 'La línea del extracto es de otra cuenta.'; end if;
  if jl.account_id <> acc.account_id or jl.organization_id <> r.organization_id then raise exception 'El movimiento contable no corresponde a la cuenta bancaria.'; end if;
  select * into je from journal_entries where id = jl.entry_id;
  if je.status <> 'posted' then raise exception 'Solo se concilian movimientos contabilizados.'; end if;
  if je.currency_code <> acc.currency_code then raise exception 'El movimiento contable está en otra moneda que la cuenta bancaria.'; end if;
  s_signed := sl.credit - sl.debit; j_signed := jl.debit - jl.credit;
  if s_signed = 0 or j_signed = 0 or sign(s_signed) <> sign(j_signed) then raise exception 'El sentido (ingreso/egreso) del extracto y del movimiento contable no coincide.'; end if;
  select coalesce(sum(amount), 0) into s_used from bank_reconciliation_matches where statement_line_id = p_stmt and status = 'active';
  select coalesce(sum(amount), 0) into j_used from bank_reconciliation_matches where journal_line_id = p_jline and status = 'active';
  if p_amount <= 0 or p_amount > abs(s_signed) - s_used then raise exception 'El importe supera lo pendiente de conciliar de la línea del extracto.'; end if;
  if p_amount > abs(j_signed) - j_used then raise exception 'El importe supera lo pendiente de conciliar del movimiento contable (ya usado en otra conciliación).'; end if;
  insert into bank_reconciliation_matches(organization_id, reconciliation_id, statement_line_id, journal_line_id, amount, match_type)
  values (r.organization_id, p_recon, p_stmt, p_jline, p_amount, case when p_type = 'auto' then 'auto' else 'manual' end) returning id into mid;
  perform app_private.refresh_statement_lines(p_stmt, null);
  perform app_private.log_audit(r.organization_id, 'bank_match', 'bank_reconciliation_matches', mid::text, null, null,
          jsonb_build_object('statement_line', p_stmt, 'journal_line', p_jline, 'amount', p_amount));
  return mid;
end $$;

create or replace function public.bank_unmatch(p_match uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare m bank_reconciliation_matches; r bank_reconciliations;
begin
  select * into m from bank_reconciliation_matches where id = p_match for update;
  if m.id is null then raise exception 'Coincidencia inexistente.'; end if;
  select * into r from bank_reconciliations where id = m.reconciliation_id for update;
  perform app_private.require_perm(r.organization_id, 'bank.reconcile');
  if r.status not in ('draft','rejected') then raise exception 'La conciliación ya fue enviada o cerrada: devuélvala a borrador para modificarla.'; end if;
  update bank_reconciliation_matches set status = 'undone', undone_by = auth.uid(), undone_at = now(), undone_reason = p_reason where id = p_match;
  perform app_private.refresh_statement_lines(m.statement_line_id, null);
  perform app_private.log_audit(r.organization_id, 'bank_unmatch', 'bank_reconciliation_matches', p_match::text, p_reason);
end $$;

create or replace function public.bank_set_ignored(p_line uuid, p_ignored boolean) returns void
language plpgsql security definer set search_path = public as $$
declare sl bank_statement_lines;
begin
  select * into sl from bank_statement_lines where id = p_line for update;
  perform app_private.require_perm(sl.organization_id, 'bank.reconcile');
  if sl.matched_amount > 0 then raise exception 'La línea tiene conciliaciones activas.'; end if;
  perform set_config('app.allow_post', 'on', true);
  update bank_statement_lines set match_status = case when p_ignored then 'ignored' else 'unmatched' end where id = p_line;
  perform set_config('app.allow_post', 'off', true);
end $$;

-- Propuesta de ajuste (comisión, interés, cargo): crea un asiento en BORRADOR que debe aprobarse
create or replace function public.create_bank_adjustment(p_recon uuid, p_stmt uuid, p_type text, p_counter uuid, p_description text) returns uuid
language plpgsql security definer set search_path = public as $$
declare r bank_reconciliations; sl bank_statement_lines; acc cash_bank_accounts; je uuid; amt numeric; rate numeric := 1; basecur char(3); aid uuid; txt text;
begin
  select * into r from bank_reconciliations where id = p_recon for update;
  perform app_private.require_perm(r.organization_id, 'bank.reconcile');
  perform app_private.require_perm(r.organization_id, 'journal.create');
  if r.status not in ('draft','rejected') then raise exception 'La conciliación no es editable.'; end if;
  select * into sl from bank_statement_lines where id = p_stmt for update;
  select * into acc from cash_bank_accounts where id = r.cash_bank_account_id;
  if sl.cash_bank_account_id <> acc.id then raise exception 'La línea es de otra cuenta.'; end if;
  if sl.matched_amount > 0 then raise exception 'La línea ya tiene conciliaciones.'; end if;
  if exists(select 1 from bank_reconciliation_adjustments where statement_line_id = p_stmt) then raise exception 'Ya existe un ajuste para esta línea.'; end if;
  if not exists(select 1 from accounts where id = p_counter and organization_id = r.organization_id and is_postable and active) then raise exception 'Cuenta contrapartida inválida.'; end if;
  amt := abs(sl.credit - sl.debit);
  select base_currency into basecur from organizations where id = r.organization_id;
  if acc.currency_code <> basecur then
    select rate into rate from exchange_rates where organization_id = r.organization_id and currency_code = acc.currency_code and rate_date <= sl.line_date order by rate_date desc limit 1;
    if rate is null then raise exception 'Registre un tipo de cambio para % a la fecha %.', acc.currency_code, sl.line_date; end if;
  end if;
  txt := coalesce(nullif(p_description, ''), sl.description, 'Ajuste bancario');
  perform set_config('app.allow_post', 'on', true);
  je := app_private.je_new(r.organization_id, sl.line_date, 'Ajuste bancario: ' || txt, sl.reference, acc.currency_code, rate, 'manual', null, null);
  if sl.debit > 0 then
    perform app_private.je_line(je, r.organization_id, p_counter, null, txt, amt, 0, round(amt * rate, 2), 0);
    perform app_private.je_line(je, r.organization_id, acc.account_id, null, txt, 0, amt, 0, round(amt * rate, 2));
  else
    perform app_private.je_line(je, r.organization_id, acc.account_id, null, txt, amt, 0, round(amt * rate, 2), 0);
    perform app_private.je_line(je, r.organization_id, p_counter, null, txt, 0, amt, 0, round(amt * rate, 2));
  end if;
  insert into bank_reconciliation_adjustments(organization_id, reconciliation_id, statement_line_id, adjustment_type, description, counter_account_id, journal_entry_id)
  values (r.organization_id, p_recon, p_stmt, p_type, txt, p_counter, je) returning id into aid;
  perform set_config('app.allow_post', 'off', true);
  perform app_private.log_audit(r.organization_id, 'bank_adjustment_proposed', 'bank_reconciliation_adjustments', aid::text, txt);
  return je;
end $$;

-- ---------- Reportes ----------
create or replace function public.report_account_balances(p_org uuid, p_from date, p_to date)
returns table (account_id uuid, activity_id uuid, opening_debit numeric, opening_credit numeric, period_debit numeric, period_credit numeric)
language sql stable security invoker set search_path = public as $$
  select l.account_id, l.activity_id,
    coalesce(sum(l.debit_base) filter (where e.entry_date < p_from), 0),
    coalesce(sum(l.credit_base) filter (where e.entry_date < p_from), 0),
    coalesce(sum(l.debit_base) filter (where e.entry_date between p_from and p_to), 0),
    coalesce(sum(l.credit_base) filter (where e.entry_date between p_from and p_to), 0)
  from journal_entry_lines l join journal_entries e on e.id = l.entry_id
  where l.organization_id = p_org and e.status = 'posted' and e.entry_date <= p_to
  group by l.account_id, l.activity_id
$$;

create or replace function public.report_inventory_vs_ledger(p_org uuid)
returns table (inventory_value numeric, ledger_balance numeric)
language sql stable security invoker set search_path = public as $$
  select (select coalesce(sum(inventory_value), 0) from products where organization_id = p_org),
         (select coalesce(sum(l.debit_base - l.credit_base), 0) from journal_entry_lines l join journal_entries e on e.id = l.entry_id
           where l.organization_id = p_org and e.status = 'posted'
             and l.account_id in (select a.id from accounts a where a.organization_id = p_org and (a.id in (select account_id from accounting_rules where organization_id = p_org and rule_key = 'inventory.asset')
                 or a.id in (select inventory_account_id from products where organization_id = p_org and inventory_account_id is not null))))
$$;

-- =====================================================================
-- PARTE 8: TRIGGERS, SEGURIDAD A NIVEL DE FILA (RLS) Y PERMISOS
-- =====================================================================

-- ---------- Triggers de documentos ----------
do $$
declare r record;
begin
  for r in select * from (values
    ('journal_entries',      null,                   'entry_number=null,entry_kind="manual",source_type=null,source_id=null,reverses_entry_id=null,reversed_by_entry_id=null,total_debit_base=0,total_credit_base=0', 'currency_code:currencies'),
    ('purchase_invoices',    'purchase_invoice',     'doc_number=null,subtotal=0,tax_total=0,total=0,total_base=0,paid_amount=0,paid_base_carried=0,journal_entry_id=null', 'supplier_id:suppliers'),
    ('sales_invoices',       'sales_invoice',        'doc_number=null,subtotal=0,tax_total=0,total=0,total_base=0,paid_amount=0,paid_base_carried=0,journal_entry_id=null', 'customer_id:customers'),
    ('supplier_payments',    'supplier_payment',     'doc_number=null,journal_entry_id=null', 'supplier_id:suppliers,cash_bank_account_id:cash_bank_accounts,payment_method_id:payment_methods'),
    ('customer_receipts',    'customer_receipt',     'doc_number=null,journal_entry_id=null', 'customer_id:customers,cash_bank_account_id:cash_bank_accounts,payment_method_id:payment_methods'),
    ('cash_movements',       'cash_movement',        'doc_number=null,journal_entry_id=null', 'cash_bank_account_id:cash_bank_accounts,to_cash_bank_account_id:cash_bank_accounts,counter_account_id:accounts,activity_id:activities'),
    ('inventory_adjustments','inventory_adjustment', 'doc_number=null,journal_entry_id=null', ''),
    ('bank_reconciliations', 'bank_reconciliation',  'doc_number=null', 'cash_bank_account_id:cash_bank_accounts')
  ) as t(tbl, doctype, prot, refs) loop
    -- se pasan los argumentos como literales separados por coma
    execute format('create trigger a1_guard before insert or update or delete on public.%I for each row execute function app_private.trg_guard_document(%s)',
      r.tbl, (select string_agg(quote_literal(x), ',') from unnest(string_to_array(r.prot, ',')) x));
    if r.refs <> '' then
      execute format('create trigger a2_same_org before insert or update on public.%I for each row execute function app_private.trg_same_org(%s)',
        r.tbl, (select string_agg(quote_literal(x), ',') from unnest(string_to_array(r.refs, ',')) x));
    end if;
    if r.doctype is not null then
      execute format('create trigger a3_number before insert on public.%I for each row execute function app_private.trg_assign_number(%L)', r.tbl, r.doctype);
    end if;
  end loop;
end $$;
-- la referencia de moneda en journal_entries no pertenece a una empresa: se retira
drop trigger if exists a2_same_org on public.journal_entries;

-- Triggers de líneas
create trigger a1_guard before insert or update or delete on public.purchase_invoice_lines for each row execute function app_private.trg_guard_line('purchase_invoices','invoice_id');
create trigger a2_same_org before insert or update on public.purchase_invoice_lines for each row execute function app_private.trg_same_org('product_id:products','account_id:accounts','tax_type_id:tax_types','activity_id:activities');
create trigger a3_calc before insert or update on public.purchase_invoice_lines for each row execute function app_private.trg_calc_invoice_line();
create trigger z_after after insert or update or delete on public.purchase_invoice_lines for each row execute function app_private.trg_after_line('purchase_invoices','invoice_id');

create trigger a1_guard before insert or update or delete on public.sales_invoice_lines for each row execute function app_private.trg_guard_line('sales_invoices','invoice_id');
create trigger a2_same_org before insert or update on public.sales_invoice_lines for each row execute function app_private.trg_same_org('product_id:products','account_id:accounts','tax_type_id:tax_types','activity_id:activities');
create trigger a3_calc before insert or update on public.sales_invoice_lines for each row execute function app_private.trg_calc_invoice_line();
create trigger z_after after insert or update or delete on public.sales_invoice_lines for each row execute function app_private.trg_after_line('sales_invoices','invoice_id');

create trigger a1_guard before insert or update or delete on public.journal_entry_lines for each row execute function app_private.trg_guard_line('journal_entries','entry_id');
create trigger a2_same_org before insert or update on public.journal_entry_lines for each row execute function app_private.trg_same_org('account_id:accounts','activity_id:activities');
create trigger a3_calc before insert or update on public.journal_entry_lines for each row execute function app_private.trg_calc_journal_line();
create trigger z_after after insert or update or delete on public.journal_entry_lines for each row execute function app_private.trg_after_line('journal_entries','entry_id');

create trigger a1_guard before insert or update or delete on public.inventory_adjustment_lines for each row execute function app_private.trg_guard_line('inventory_adjustments','adjustment_id');
create trigger a2_same_org before insert or update on public.inventory_adjustment_lines for each row execute function app_private.trg_same_org('product_id:products','activity_id:activities');

create trigger a3_lineno before insert on public.inventory_adjustment_lines for each row execute function app_private.trg_auto_line_no('adjustment_id');

create trigger a1_guard before insert or update or delete on public.supplier_payment_allocations for each row execute function app_private.trg_guard_line('supplier_payments','payment_id');
create trigger a2_same_org before insert or update on public.supplier_payment_allocations for each row execute function app_private.trg_same_org('invoice_id:purchase_invoices');
create trigger a3_protect before insert or update on public.supplier_payment_allocations for each row execute function app_private.trg_protect('carried_base=null');
create trigger a1_guard before insert or update or delete on public.customer_receipt_allocations for each row execute function app_private.trg_guard_line('customer_receipts','receipt_id');
create trigger a2_same_org before insert or update on public.customer_receipt_allocations for each row execute function app_private.trg_same_org('invoice_id:sales_invoices');
create trigger a3_protect before insert or update on public.customer_receipt_allocations for each row execute function app_private.trg_protect('carried_base=null');

-- Referencias entre empresas en tablas maestras
create trigger a2_same_org before insert or update on public.accounts for each row execute function app_private.trg_same_org('parent_id:accounts');
create trigger a3_guard before insert or update on public.accounts for each row execute function app_private.trg_guard_account();
create trigger a2_same_org before insert or update on public.tax_types for each row execute function app_private.trg_same_org('account_id:accounts');
create trigger a2_same_org before insert or update on public.accounting_rules for each row execute function app_private.trg_same_org('account_id:accounts');
create trigger a2_same_org before insert or update on public.cash_bank_accounts for each row execute function app_private.trg_same_org('account_id:accounts');
create trigger a2_same_org before insert or update on public.products for each row execute function app_private.trg_same_org('inventory_account_id:accounts','revenue_account_id:accounts','cogs_account_id:accounts','expense_account_id:accounts');
create trigger a1_protect before insert or update on public.products for each row execute function app_private.trg_protect('qty_on_hand=0','inventory_value=0','avg_cost=0');
create trigger a3_guard before update on public.products for each row execute function app_private.trg_guard_product();
create trigger a2_same_org before insert or update on public.financial_statement_rows for each row execute function app_private.trg_same_org('template_id:financial_statement_templates');
create trigger a2_same_org before insert or update on public.financial_statement_mappings for each row execute function app_private.trg_same_org('row_id:financial_statement_rows','account_id:accounts');
create trigger a1_guard before update on public.organizations for each row execute function app_private.trg_guard_org();
create trigger a1_guard before update on public.inventory_settings for each row execute function app_private.trg_guard_inv_settings();
create trigger a1_guard before update on public.document_sequences for each row execute function app_private.trg_guard_sequence();
create trigger a1_guard before update on public.profiles for each row execute function app_private.trg_guard_profile();

-- Auditoría automática
do $$
declare t text;
begin
  foreach t in array array['organizations','organization_members','role_permissions','exchange_rates','accounting_periods','accounts','activities',
    'tax_types','accounting_rules','document_sequences','payment_methods','inventory_settings','suppliers','customers','products','cash_bank_accounts',
    'financial_statement_templates','financial_statement_rows','financial_statement_mappings','approval_workflows','attachments',
    'journal_entries','purchase_invoices','sales_invoices','supplier_payments','customer_receipts','cash_movements',
    'inventory_adjustments','bank_reconciliations','profiles'] loop
    execute format('create trigger z_audit after insert or update or delete on public.%I for each row execute function app_private.trg_audit_row()', t);
  end loop;
end $$;

-- ---------- Seguridad a nivel de fila (RLS) ----------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

create or replace function public.shares_org_with(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from organization_members a join organization_members b on a.organization_id = b.organization_id
                where a.user_id = auth.uid() and a.active and b.user_id = p_user)
$$;

create or replace function public.has_any_perm(p_org uuid, p_perms text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from unnest(p_perms) x where public.has_perm(p_org, x))
$$;

-- Crea políticas estándar: lectura con "data.view"; escritura con cualquiera de los permisos indicados
create or replace function app_private.mk_policies(p_tbl text, p_write text[], p_ops text default 'iud') returns void
language plpgsql as $$
declare w text := format('public.has_any_perm(organization_id, %L::text[])', p_write);
begin
  execute format('create policy sel on public.%I for select to authenticated using (public.has_perm(organization_id, ''data.view''))', p_tbl);
  if p_write is not null then
    if p_ops like '%i%' then execute format('create policy ins on public.%I for insert to authenticated with check (%s)', p_tbl, w); end if;
    if p_ops like '%u%' then execute format('create policy upd on public.%I for update to authenticated using (%s) with check (%s)', p_tbl, w, w); end if;
    if p_ops like '%d%' then execute format('create policy del on public.%I for delete to authenticated using (%s)', p_tbl, w); end if;
  end if;
end $$;

do $$
declare r record;
begin
  for r in select * from (values
    ('journal_entries','{journal.create}'),('journal_entry_lines','{journal.create}'),
    ('purchase_invoices','{purchases.create}'),('purchase_invoice_lines','{purchases.create}'),
    ('sales_invoices','{sales.create}'),('sales_invoice_lines','{sales.create}'),
    ('supplier_payments','{payments.create}'),('supplier_payment_allocations','{payments.create}'),
    ('customer_receipts','{receipts.create}'),('customer_receipt_allocations','{receipts.create}'),
    ('cash_movements','{treasury.create}'),
    ('inventory_adjustments','{inventory.create}'),('inventory_adjustment_lines','{inventory.create}'),
    ('suppliers','{masters.manage}'),('customers','{masters.manage}'),('products','{masters.manage}'),('cash_bank_accounts','{masters.manage}'),
    ('accounts','{accounts.manage}'),('activities','{accounts.manage}'),('accounting_rules','{accounts.manage}'),
    ('financial_statement_templates','{accounts.manage}'),('financial_statement_rows','{accounts.manage}'),('financial_statement_mappings','{accounts.manage}'),
    ('exchange_rates','{config.manage,accounts.manage}'),('tax_types','{config.manage,accounts.manage}'),
    ('payment_methods','{config.manage}'),('approval_workflows','{config.manage}'),
    ('bank_reconciliations','{bank.reconcile}')
  ) as t(tbl, perms) loop
    perform app_private.mk_policies(r.tbl, r.perms::text[]);
  end loop;
  -- solo lectura / actualización limitada
  perform app_private.mk_policies('document_sequences', '{config.manage}', 'u');
  perform app_private.mk_policies('inventory_settings', '{config.manage}', 'u');
  perform app_private.mk_policies('accounting_periods', null);
  perform app_private.mk_policies('accounting_close_runs', null);
  perform app_private.mk_policies('approval_requests', null);
  perform app_private.mk_policies('approval_steps', null);
  perform app_private.mk_policies('approval_history', null);
  perform app_private.mk_policies('inventory_movements', null);
  perform app_private.mk_policies('inventory_cost_layers', null);
  perform app_private.mk_policies('bank_statement_imports', null);
  perform app_private.mk_policies('bank_statement_lines', null);
  perform app_private.mk_policies('bank_reconciliation_matches', null);
  perform app_private.mk_policies('bank_reconciliation_adjustments', null);
end $$;

-- Adjuntos: el archivo debe estar dentro de la carpeta de su empresa
create policy sel on public.attachments for select to authenticated using (public.has_perm(organization_id, 'data.view'));
create policy ins on public.attachments for insert to authenticated
  with check (public.has_perm(organization_id, 'attachments.manage') and storage_path like organization_id::text || '/%');
create policy del on public.attachments for delete to authenticated using (public.has_perm(organization_id, 'attachments.manage'));

-- Tablas especiales
create policy sel on public.currencies for select to authenticated using (true);
create policy sel on public.organizations for select to authenticated using (public.is_member(id));
create policy upd on public.organizations for update to authenticated using (public.has_perm(id, 'config.manage')) with check (public.has_perm(id, 'config.manage'));
create policy sel on public.profiles for select to authenticated using (id = auth.uid() or public.shares_org_with(id) or public.is_platform_admin());
create policy upd on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy sel on public.organization_members for select to authenticated using (user_id = auth.uid() or public.is_member(organization_id));
create policy sel on public.role_permissions for select to authenticated using (public.is_member(organization_id));
create policy sel on public.audit_logs for select to authenticated using (public.has_perm(organization_id, 'audit.view'));

-- ---------- Almacenamiento de archivos adjuntos (bucket privado) ----------
insert into storage.buckets(id, name, public) values ('attachments', 'attachments', false) on conflict (id) do nothing;

create or replace function public.storage_org(p_name text) returns uuid language sql immutable as $$
  select case when split_part(p_name, '/', 1) ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
              then split_part(p_name, '/', 1)::uuid end
$$;
create policy "adjuntos_leer" on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and public.has_perm(public.storage_org(name), 'data.view'));
create policy "adjuntos_subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and public.has_perm(public.storage_org(name), 'attachments.manage'));
create policy "adjuntos_borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and public.has_perm(public.storage_org(name), 'attachments.manage'));

-- ---------- Permisos de ejecución ----------
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke all on schema app_private from public, anon, authenticated;
revoke all on all functions in schema app_private from public, anon, authenticated;

-- =====================================================================
-- PARTE FINAL: CREAR EL USUARIO ADMINISTRADOR GENERAL
-- =====================================================================
do $$
declare e text; p text; n text; uid uuid;
begin
  select email, password, full_name into e, p, n from public._instalacion;
  uid := app_private.create_auth_user(e, p, n, true);
  drop table public._instalacion;
  raise notice 'Instalación completa. Administrador creado: %', e;
end $$;
