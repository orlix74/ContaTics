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

