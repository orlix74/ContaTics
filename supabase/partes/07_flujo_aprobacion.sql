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
