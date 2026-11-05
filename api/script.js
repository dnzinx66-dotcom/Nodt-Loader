import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export default async function handler(req, res) {
  try {
    // Procura o script_final.lua na mesma pasta que este arquivo JS (a pasta api)
    const filePath = path.join(__dirname, 'script_final.lua');
    const scriptBody = fs.readFileSync(filePath, 'utf8');
    
    res.setHeader("Content-Type", "text/plain");
    res.setHeader("Access-Control-Allow-Origin", "*");
    return res.status(200).send(scriptBody);
    
  } catch (error) {
    return res.status(500).send(`error("Erro Vercel: ${error.message}")`);
  }
}
