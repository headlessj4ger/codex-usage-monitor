const {DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync(':memory:');db.close();process.stdout.write(process.version);
