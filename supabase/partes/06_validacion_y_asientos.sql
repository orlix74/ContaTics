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
