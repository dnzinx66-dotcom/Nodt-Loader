import fs from 'fs';
import path from 'path';

export default async function handler(req, res) {
  try {
    const filePath = path.join(process.cwd(), 'NodtHub_v46_com_Auth_Delta_Premium.lua');
    const scriptBody = fs.readFileSync(filePath, 'utf8');
    
    res.setHeader("Content-Type", "text/plain");
    res.setHeader("Access-Control-Allow-Origin", "*");
    return res.status(200).send(scriptBody);
    
  } catch (error) {
    return res.status(500).send(`error("Erro no servidor Vercel: ${error.message}")`);
  }
}
