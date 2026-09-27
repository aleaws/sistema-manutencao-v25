-- 1. No Supabase: Authentication > Users > Add user > Create new user.
-- Use seu e-mail e uma senha. Para cadastro manual, marque e-mail confirmado.
-- 2. Troque SEU_EMAIL_AQUI abaixo pelo e-mail criado e execute este bloco.
DO $$
DECLARE uid uuid;
BEGIN
 SELECT id INTO uid FROM auth.users WHERE lower(email)=lower('SEU_EMAIL_AQUI');
 IF uid IS NULL THEN RAISE EXCEPTION 'Crie o usuario e preencha SEU_EMAIL_AQUI antes de executar'; END IF;
 INSERT INTO public.mi_members(user_id,name,role,active) VALUES(uid,'Alexandre Willian','admin',true)
 ON CONFLICT(user_id) DO UPDATE SET name=excluded.name,role='admin',active=true;
END $$;
