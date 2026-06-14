function verificarPermissao(pagina){

let usuario =
localStorage.getItem(
"usuarioLogado"
);

const permissoes = {

Alexandre:["*"],

Diretoria:["*"],

PCP:[
"03_Manutencao.html",
"04_Maquinas.html",
"05_Dispositivos.html"
],

Engenharia:[
"04_Maquinas.html",
"05_Dispositivos.html",
"06_Melhorias.html"
],



};

if(!usuario){

alert("Faça login");

window.location.href =
"index.html";

return;

}

if(
permissoes[usuario] &&
permissoes[usuario].includes("*")
){

return;

}

if(
!permissoes[usuario] ||
!permissoes[usuario].includes(pagina)
){

registrarLog(
"Acesso negado: " + pagina
);

alert("Acesso negado");

window.location.href =
"00_Sistema_Manutencao_V25.html";

}

}

function somenteLeitura(){

let usuario =
localStorage.getItem(
"usuarioLogado"
);

return (
usuario==="PCP" ||
usuario==="Engenharia"
);

}

function registrarLog(acao){

let logs =
JSON.parse(
localStorage.getItem(
"logs_auditoria"
) || "[]"
);

logs.unshift({

data:
new Date().toLocaleString(),

usuario:
localStorage.getItem(
"usuarioLogado"
) || "Desconhecido",

acao:acao

});

localStorage.setItem(
"logs_auditoria",
JSON.stringify(logs)
);

}