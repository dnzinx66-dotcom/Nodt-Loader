import fs from 'fs';
import path from 'path';

export default async function handler(req, res) {
  try {
    // process.cwd() é o jeito que a Vercel recomenda para achar arquivos na raiz
    const filePath = path.join(process.cwd(), 'script_final.lua');
    const scriptBody = fs.readFileSync(filePath, 'utf8');
    
    res.setHeader("Content-Type", "text/plain");
    res.setHeader("Access-Control-Allow-Origin", "*");
    return res.status(200).send(scriptBody);
    
  } catch (error) {
    return res.status(500).send(`error("Erro Vercel: ${error.message}")`);
  }
}
