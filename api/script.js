export default async function handler(req, res) {
  // Pega o token que o script do cliente mandou no Header
  const authHeader = req.headers.authorization;
  let token = authHeader ? authHeader.replace("Bearer ", "") : "";

  // Pega o hwid do cliente se ele mandar
  const hwid = req.headers["x-hwid"] || "";
  
  // Faz a chamada pro seu backend no Manus
  const manusUrl = "https://nodtkey-mr2kymqx.manus.space/api/script";
  
  try {
    const response = await fetch(manusUrl, {
      method: "GET",
      headers: {
        "Authorization": "Bearer " + token,
        "x-hwid": hwid
      }
    });

    if (!response.ok) {
      return res.status(response.status).send(await response.text());
    }

    const scriptBody = await response.text();
    
    res.setHeader("Content-Type", "text/plain");
    res.setHeader("Access-Control-Allow-Origin", "*");
    return res.status(200).send(scriptBody);
    
  } catch (error) {
    return res.status(500).send(`error("Erro de conexao com o servidor: ${error.message}")`);
  }
}
