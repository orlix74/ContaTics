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
