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
