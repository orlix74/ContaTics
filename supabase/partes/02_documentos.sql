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
  /*DOC*/
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
  /*DOC*/
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
  /*DOC*/
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
  /*DOC*/
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
  /*DOC*/
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
  /*DOC*/,
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
  /*DOC*/
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
  /*DOC*/,
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
