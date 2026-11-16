const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../.build/fixtures');
fs.mkdirSync(root,{recursive:true});
module.exports=root;
