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
