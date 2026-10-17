import re,glob
doc = """status public.doc_status not null default 'draft',
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  approved_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  rejection_reason text"""
out=[]
for f in sorted(glob.glob('partes/*.sql')):
    out.append(open(f).read().replace('/*DOC*/',doc))
open('01_instalar_base_de_datos.sql','w').write('\n'.join(out))
print(len('\n'.join(out).splitlines()),'lineas')
