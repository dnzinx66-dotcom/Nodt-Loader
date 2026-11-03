export default async function handler(req, res) {
  const githubUrl = "https://raw.githubusercontent.com/dnzinx66-dotcom/N0dtHub/refs/heads/main/NodtHub_v46_com_Auth_Delta_Premium.lua?token=GHSAT0AAAAAAEOQMDWG7NFOLYEM2SSCDL2C2XKLXPA";

  try {
    const response = await fetch(githubUrl);
    
    if (!response.ok) {
      return res.status(response.status).send('error("Erro ao carregar o script base.")');
    }

    const scriptBody = await response.text();
    
    res.setHeader("Content-Type", "text/plain");
    res.setHeader("Access-Control-Allow-Origin", "*");
    return res.status(200).send(scriptBody);
    
  } catch (error) {
    return res.status(500).send(`error("Erro no servidor Vercel: ${error.message}")`);
  }
}
