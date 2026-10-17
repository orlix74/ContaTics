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
