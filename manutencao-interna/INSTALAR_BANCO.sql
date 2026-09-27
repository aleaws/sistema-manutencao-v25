-- Execute uma vez no SQL Editor do Supabase usado pelo V25.
-- Cria APENAS objetos mi_*. Nao modifica tabelas ou dados do V25.
BEGIN;
CREATE TABLE IF NOT EXISTS public.mi_members (
 user_id uuid PRIMARY KEY REFERENCES auth.users(id), name text NOT NULL CHECK(length(name) BETWEEN 1 AND 150),
 role text NOT NULL CHECK(role IN ('admin','tecnico','solicitante')), active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS public.mi_store (
 id text PRIMARY KEY CHECK(id='manutencao-interna'), revision bigint NOT NULL DEFAULT 0,
 data jsonb NOT NULL DEFAULT '{"orders":[],"equipment":[],"plans":[],"costs":[],"events":[],"erp":[],"notifications":[]}'::jsonb
);
INSERT INTO public.mi_store(id) VALUES('manutencao-interna') ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS public.mi_receipts (
 user_id uuid NOT NULL REFERENCES auth.users(id), operation_id uuid NOT NULL, received_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,operation_id)
);
ALTER TABLE public.mi_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mi_store ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mi_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mi_members,public.mi_store,public.mi_receipts FROM anon,authenticated;

CREATE OR REPLACE FUNCTION public.mi_snapshot() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m public.mi_members; s public.mi_store; members jsonb;
BEGIN
 SELECT * INTO m FROM public.mi_members WHERE user_id=auth.uid() AND active;
 IF NOT FOUND THEN RAISE EXCEPTION 'ACESSO: usuario sem permissao neste sistema'; END IF;
 SELECT * INTO s FROM public.mi_store WHERE id='manutencao-interna';
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',user_id,'name',name,'role',role,'active',active) ORDER BY name),'[]') INTO members FROM public.mi_members;
 RETURN jsonb_build_object('revision',s.revision,'data',s.data,'members',members,'me',to_jsonb(m),'server_time',now());
END $$;

CREATE OR REPLACE FUNCTION public.mi_apply(operation_id uuid, payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m public.mi_members; s public.mi_store; d jsonb; p jsonb; o jsonb; old jsonb; e jsonb; pl jsonb; item jsonb;
 kind text; oid text; idx integer; pidx integer; target uuid; recipient uuid; k text; msg text; rev integer;
 qty numeric; price numeric; total bigint; month text; tzdate date; timestamp_text text; newstate jsonb; person uuid;
BEGIN
 SELECT * INTO m FROM public.mi_members WHERE user_id=auth.uid() AND active;
 IF NOT FOUND THEN RAISE EXCEPTION 'ACESSO: usuario sem permissao'; END IF;
 IF operation_id IS NULL OR payload IS NULL OR pg_column_size(payload)>30000 THEN RAISE EXCEPTION 'VALIDACAO: operacao invalida'; END IF;
 SELECT * INTO s FROM public.mi_store WHERE id='manutencao-interna' FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.mi_receipts r WHERE r.user_id=auth.uid() AND r.operation_id=mi_apply.operation_id) THEN RETURN public.mi_snapshot(); END IF;
 d=s.data; p=payload->'data'; kind=payload->>'kind'; oid=p->>'id';
 timestamp_text=to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
 tzdate=(now() AT TIME ZONE 'America/Sao_Paulo')::date;
 IF kind NOT IN ('open','update','cost','equipment','plan','plan_active','ack','erp','erp_reopen','member') OR kind IS NULL THEN RAISE EXCEPTION 'VALIDACAO: acao desconhecida'; END IF;
 IF kind IN ('equipment','plan','plan_active','erp','erp_reopen','member') AND m.role<>'admin' THEN RAISE EXCEPTION 'ACESSO: somente gestao'; END IF;
 IF kind IN ('update','cost') AND m.role='solicitante' THEN RAISE EXCEPTION 'ACESSO: somente manutencao ou gestao'; END IF;
 IF kind IN ('open','equipment','plan','cost') THEN PERFORM oid::uuid; IF oid IS NULL THEN RAISE EXCEPTION 'VALIDACAO: identificador ausente'; END IF; END IF;

 IF kind='open' THEN
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(d->'orders') x WHERE x->>'id'=oid) THEN RAISE EXCEPTION 'VALIDACAO: identificador de OS ja existe'; END IF;
  IF COALESCE(p->>'plan_id','')<>'' THEN
   SELECT x INTO pl FROM jsonb_array_elements(d->'plans') x WHERE x->>'id'=p->>'plan_id' AND (x->>'active')::boolean;
   IF pl IS NULL THEN RAISE EXCEPTION 'VALIDACAO: plano inexistente ou pausado'; END IF;
   IF m.role<>'admin' AND pl->>'responsible'<>m.user_id::text THEN RAISE EXCEPTION 'ACESSO: somente responsavel gera preventiva'; END IF;
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(d->'orders') x WHERE x->>'plan_id'=pl->>'id' AND x->>'status'<>'Fechada') THEN RAISE EXCEPTION 'CONFLITO: este plano ja tem OS aberta'; END IF;
   SELECT x INTO e FROM jsonb_array_elements(d->'equipment') x WHERE x->>'id'=pl->>'equipment_id';
   p=p||jsonb_build_object('machine',(e->>'code')||' · '||(e->>'name'),'equipment',e->>'details','sector',e->>'sector','location',e->>'location','maintenance','Preventiva','service','Rotina preventiva','description',pl->>'items','responsible',pl->>'responsible','due',pl->>'next_date');
  END IF;
  FOREACH k IN ARRAY ARRAY['machine','equipment','sector','location','maintenance','service','description','responsible'] LOOP
   IF length(trim(COALESCE(p->>k,'')))=0 OR length(p->>k)>5000 THEN RAISE EXCEPTION 'VALIDACAO: preencha %',k; END IF;
  END LOOP;
  IF p->>'maintenance' NOT IN ('Corretiva','Preventiva','Preditiva','Lubrificação','Inspeção','A definir') THEN RAISE EXCEPTION 'VALIDACAO: manutencao invalida'; END IF;
  target=(p->>'responsible')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.mi_members WHERE user_id=target AND active AND role IN ('admin','tecnico')) THEN RAISE EXCEPTION 'VALIDACAO: responsavel invalido'; END IF;
  IF COALESCE(p->>'due','')<>'' THEN PERFORM (p->>'due')::date; END IF;
  o=jsonb_build_object('id',oid,'code','OS-'||to_char(tzdate,'YYYY')||'-'||lpad((jsonb_array_length(d->'orders')+1)::text,5,'0'),
   'created',timestamp_text,'recorded_at',left(COALESCE(p->>'recorded_at',timestamp_text),40),'creator',m.user_id,
   'original',jsonb_build_object('requester',m.name,'machine',p->>'machine','equipment',p->>'equipment','sector',p->>'sector','location',p->>'location','maintenance',p->>'maintenance','service',p->>'service','description',p->>'description','priority',COALESCE(p->>'priority','Normal'),'responsible',target),
   'responsible',target,'actual_type','','actual_service','','status','Aberta','due',COALESCE(p->>'due',''),'conclusion','','revision',1,'plan_id',COALESCE(p->>'plan_id',''));
  d=jsonb_set(d,'{orders}',(d->'orders')||jsonb_build_array(o));
  msg='Abertura: '||(p->>'description');
  d=jsonb_set(d,'{notifications}',(d->'notifications')||jsonb_build_array(jsonb_build_object('id',operation_id,'user_id',target,'order_id',oid,'text',o->>'code'||' atribuída a você','created',timestamp_text,'seen',false)));
 ELSIF kind='update' THEN
  SELECT x,(ord-1)::integer INTO o,idx FROM jsonb_array_elements(d->'orders') WITH ORDINALITY a(x,ord) WHERE x->>'id'=oid;
  IF o IS NULL THEN RAISE EXCEPTION 'VALIDACAO: OS nao encontrada'; END IF;
  IF m.role<>'admin' AND o->>'responsible'<>m.user_id::text THEN RAISE EXCEPTION 'ACESSO: esta OS tem outro responsavel'; END IF;
  IF COALESCE((p->>'revision')::integer,-1)<>(o->>'revision')::integer THEN RAISE EXCEPTION 'CONFLITO: OS alterada em outro aparelho; revise antes de reenviar'; END IF;
  IF o->>'status'='Fechada' THEN RAISE EXCEPTION 'CONFLITO: OS ja fechada'; END IF;
  IF p ?| ARRAY['original','description','machine','created'] THEN RAISE EXCEPTION 'VALIDACAO: abertura original imutavel'; END IF;
  IF p->>'status' IS NULL OR p->>'status' NOT IN ('Aberta','Em análise','Em execução','Aguardando material','Fechada') THEN RAISE EXCEPTION 'VALIDACAO: situacao invalida'; END IF;
  IF p->>'status'='Fechada' AND length(trim(COALESCE(p->>'conclusion','')))=0 THEN RAISE EXCEPTION 'VALIDACAO: informe a conclusao'; END IF;
  target=(p->>'responsible')::uuid;
  IF target IS NULL OR NOT EXISTS(SELECT 1 FROM public.mi_members WHERE user_id=target AND active AND role IN ('admin','tecnico')) THEN RAISE EXCEPTION 'VALIDACAO: responsavel invalido'; END IF;
  IF COALESCE(p->>'due','')<>'' THEN PERFORM (p->>'due')::date; END IF;
  old=o;
  o=o||jsonb_build_object('responsible',target,'status',p->>'status','actual_type',left(COALESCE(p->>'actual_type',''),100),'actual_service',left(COALESCE(p->>'actual_service',''),100),'due',COALESCE(p->>'due',''),'conclusion',left(COALESCE(p->>'conclusion',''),5000),'revision',(o->>'revision')::integer+1,'closed',CASE WHEN p->>'status'='Fechada' THEN timestamp_text ELSE NULL END);
  d=jsonb_set(d,ARRAY['orders',idx::text],o);
  msg='Situação: '||(old->>'status')||' → '||(o->>'status')||'; manutenção real: '||(o->>'actual_type')||'; especialidade: '||(o->>'actual_service')||'; responsável: '||(o->>'responsible')||'; prazo: '||(o->>'due')||'; conclusão: '||(o->>'conclusion')||'; observação: '||left(COALESCE(p->>'note',''),5000);
  IF old->>'responsible'<>target::text THEN
   d=jsonb_set(d,'{notifications}',(d->'notifications')||jsonb_build_array(jsonb_build_object('id',operation_id,'user_id',target,'order_id',oid,'text',o->>'code'||' encaminhada a você','created',timestamp_text,'seen',false)));
  END IF;
  IF o->>'status'='Fechada' AND COALESCE(o->>'plan_id','')<>'' THEN
   SELECT x,(ord-1)::integer INTO pl,pidx FROM jsonb_array_elements(d->'plans') WITH ORDINALITY a(x,ord) WHERE x->>'id'=o->>'plan_id';
   IF pl IS NOT NULL THEN d=jsonb_set(d,ARRAY['plans',pidx::text,'next_date'],to_jsonb((tzdate+(pl->>'frequency')::integer)::text)); END IF;
  END IF;
 ELSIF kind='cost' THEN
  SELECT x INTO o FROM jsonb_array_elements(d->'orders') x WHERE x->>'id'=p->>'order_id';
  IF o IS NULL THEN RAISE EXCEPTION 'VALIDACAO: OS nao encontrada'; END IF;
  IF m.role<>'admin' AND (o->>'responsible'<>m.user_id::text OR o->>'status'='Fechada') THEN RAISE EXCEPTION 'ACESSO: somente responsavel ou gestao'; END IF;
  IF length(trim(COALESCE(p->>'description','')))=0 THEN RAISE EXCEPTION 'VALIDACAO: descreva o item'; END IF;
  qty=(p->>'quantity')::numeric; price=(p->>'price')::numeric;
  IF qty IS NULL OR price IS NULL OR NOT(qty>0 AND qty<=1000000 AND price>=0 AND price<=100000000) OR qty<>round(qty,3) THEN RAISE EXCEPTION 'VALIDACAO: quantidade ou preco invalido'; END IF;
  month=to_char(tzdate,'YYYY-MM');
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(d->'erp') x WHERE x->>'month'=month AND COALESCE((x->>'confirmed')::boolean,false)) THEN RAISE EXCEPTION 'CONFLITO: mes conferido no ERP; gestao precisa reabrir'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(d->'costs') x WHERE x->>'id'=oid) THEN RAISE EXCEPTION 'VALIDACAO: item ja existe'; END IF;
  total=round(qty*round(price*100))::bigint;
  IF total>9000000000000 THEN RAISE EXCEPTION 'VALIDACAO: valor total excede o limite'; END IF;
  item=jsonb_build_object('id',oid,'order_id',p->>'order_id','description',left(p->>'description',2000),'category',left(COALESCE(p->>'category','Material'),100),'quantity',qty,'unit',left(COALESCE(p->>'unit','un'),30),'cents',round(price*100)::bigint,'total_cents',total,'created',timestamp_text,'month',month,'actor',m.name);
  d=jsonb_set(d,'{costs}',(d->'costs')||jsonb_build_array(item));
  oid=p->>'order_id'; msg='Item: '||(item->>'description')||'; quantidade: '||qty||'; total em centavos: '||total;
 ELSIF kind='equipment' THEN
  FOREACH k IN ARRAY ARRAY['code','name','sector','location','details'] LOOP
   IF length(trim(COALESCE(p->>k,'')))=0 THEN RAISE EXCEPTION 'VALIDACAO: preencha %',k; END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(d->'equipment') x WHERE lower(x->>'code')=lower(p->>'code') OR x->>'id'=oid) THEN RAISE EXCEPTION 'CONFLITO: equipamento ja cadastrado'; END IF;
  d=jsonb_set(d,'{equipment}',(d->'equipment')||jsonb_build_array(jsonb_build_object('id',oid,'code',left(p->>'code',100),'name',left(p->>'name',200),'sector',left(p->>'sector',200),'location',left(p->>'location',200),'details',left(p->>'details',2000),'category',COALESCE(p->>'category','Máquina'))));
  msg='Equipamento cadastrado: '||(p->>'code'); oid='';
 ELSIF kind='plan' THEN
  target=(p->>'responsible')::uuid;
  IF target IS NULL OR NOT EXISTS(SELECT 1 FROM public.mi_members WHERE user_id=target AND active AND role IN ('admin','tecnico')) THEN RAISE EXCEPTION 'VALIDACAO: responsavel invalido'; END IF;
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(d->'equipment') x WHERE x->>'id'=p->>'equipment_id') THEN RAISE EXCEPTION 'VALIDACAO: equipamento ausente'; END IF;
  IF COALESCE((p->>'frequency')::integer,0) NOT BETWEEN 1 AND 3650 OR length(trim(COALESCE(p->>'items','')))=0 OR p->>'next_date' IS NULL THEN RAISE EXCEPTION 'VALIDACAO: plano incompleto'; END IF;
  PERFORM (p->>'next_date')::date;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(d->'plans') x WHERE x->>'id'=oid) THEN RAISE EXCEPTION 'VALIDACAO: plano ja existe'; END IF;
  d=jsonb_set(d,'{plans}',(d->'plans')||jsonb_build_array(jsonb_build_object('id',oid,'equipment_id',p->>'equipment_id','frequency',(p->>'frequency')::integer,'next_date',p->>'next_date','items',left(p->>'items',5000),'responsible',target,'active',true)));
  msg='Plano preventivo cadastrado'; oid='';
 ELSIF kind='plan_active' THEN
  SELECT x,(ord-1)::integer INTO pl,idx FROM jsonb_array_elements(d->'plans') WITH ORDINALITY a(x,ord) WHERE x->>'id'=oid;
  IF pl IS NULL OR p->>'active' IS NULL THEN RAISE EXCEPTION 'VALIDACAO: plano ausente'; END IF;
  d=jsonb_set(d,ARRAY['plans',idx::text,'active'],to_jsonb((p->>'active')::boolean)); msg='Plano preventivo: ativo='||(p->>'active'); oid='';
 ELSIF kind='ack' THEN
  SELECT x,(ord-1)::integer INTO item,idx FROM jsonb_array_elements(d->'notifications') WITH ORDINALITY a(x,ord) WHERE x->>'id'=oid AND x->>'user_id'=m.user_id::text;
  IF item IS NULL THEN RAISE EXCEPTION 'VALIDACAO: aviso ausente'; END IF;
  d=jsonb_set(d,ARRAY['notifications',idx::text,'seen'],'true');
 ELSIF kind IN ('erp','erp_reopen') THEN
  month=p->>'month';
  IF month IS NULL OR month !~ '^\d{4}-(0[1-9]|1[0-2])$' THEN RAISE EXCEPTION 'VALIDACAO: mes invalido'; END IF;
  SELECT COALESCE(sum((x->>'total_cents')::bigint),0) INTO total FROM jsonb_array_elements(d->'costs') x WHERE x->>'month'=month;
  IF kind='erp' AND length(trim(COALESCE(p->>'reference','')))=0 THEN RAISE EXCEPTION 'VALIDACAO: informe referencia do ERP'; END IF;
  SELECT x,(ord-1)::integer INTO item,idx FROM jsonb_array_elements(d->'erp') WITH ORDINALITY a(x,ord) WHERE x->>'month'=month;
  item=jsonb_build_object('month',month,'reference',left(COALESCE(p->>'reference',''),500),'confirmed',kind='erp','total_cents',total,'actor',m.name,'created',timestamp_text);
  IF idx IS NULL THEN d=jsonb_set(d,'{erp}',(d->'erp')||jsonb_build_array(item)); ELSE d=jsonb_set(d,ARRAY['erp',idx::text],item); END IF;
  msg='Conferencia ERP: '||month||'; confirmado='||(kind='erp')::text; oid='';
 ELSIF kind='member' THEN
  IF p->>'role' IS NULL OR p->>'role' NOT IN ('admin','tecnico','solicitante') OR length(trim(COALESCE(p->>'name','')))=0 THEN RAISE EXCEPTION 'VALIDACAO: perfil ou nome invalido'; END IF;
  SELECT id INTO person FROM auth.users WHERE lower(email)=lower(trim(p->>'email'));
  IF person IS NULL THEN RAISE EXCEPTION 'VALIDACAO: crie primeiro este usuario em Authentication no Supabase'; END IF;
  IF person=m.user_id AND (p->>'role'<>'admin' OR NOT COALESCE((p->>'active')::boolean,true)) THEN RAISE EXCEPTION 'VALIDACAO: nao remova seu proprio acesso de gestao'; END IF;
  INSERT INTO public.mi_members(user_id,name,role,active) VALUES(person,left(p->>'name',150),p->>'role',COALESCE((p->>'active')::boolean,true))
  ON CONFLICT(user_id) DO UPDATE SET name=excluded.name,role=excluded.role,active=excluded.active;
  msg='Acesso atualizado: '||(p->>'name')||'; perfil='||(p->>'role'); oid='';
 END IF;
 IF msg IS NOT NULL THEN
  d=jsonb_set(d,'{events}',(d->'events')||jsonb_build_array(jsonb_build_object('id',operation_id,'order_id',COALESCE(oid,''),'actor',m.name,'created',timestamp_text,'event',msg)));
 END IF;
 UPDATE public.mi_store SET data=d,revision=s.revision+1 WHERE id='manutencao-interna';
 INSERT INTO public.mi_receipts(user_id,operation_id) VALUES(m.user_id,mi_apply.operation_id);
 RETURN public.mi_snapshot();
END $$;
REVOKE ALL ON FUNCTION public.mi_snapshot(),public.mi_apply(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mi_snapshot(),public.mi_apply(uuid,jsonb) TO authenticated;
COMMIT;
-- Proximo passo: executar PRIMEIRO_ACESSO.sql depois de preencher seu e-mail.
