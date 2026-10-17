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
