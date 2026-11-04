export default async function handler(req, res) {
  // Em vez de ler um arquivo local, a Vercel vai pedir pro Manus entregar o script
  const manusUrl = "https://nodtkey-mr2kymqx.manus.space/api/script";

  try {
    // Repassa o token se o usuário já tiver um
    const authHeader = req.headers.authorization;
    const headers = {};
    if (authHeader) {
      headers["Authorization"] = authHeader;
    }

    const response = await fetch(manusUrl, {
      method: "GET",
      headers: headers
    });
    
    if (!response.ok) {
      return res.status(response.status).send(await response.text());
    }

    const scriptBody = await response.text();
    
    // Devolve o script pro Delta
    res.setHeader("Content-Type", "text/plain");
    res.setHeader("Access-Control-Allow-Origin", "*");
    return res.status(200).send(scriptBody);
    
  } catch (error) {
    return res.status(500).send(`error("Erro Vercel -> Manus: ${error.message}")`);
  }
}
