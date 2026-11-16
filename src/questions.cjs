'use strict';
function answerIds(content){
  const result=new Set();
  for(const part of Array.isArray(content)?content:[]){
    if(typeof part.text!=='string')continue;
    for(const match of part.text.matchAll(/<send_user_message_question_reply>([\s\S]*?)<\/send_user_message_question_reply>/g)){
      try{const replies=JSON.parse(match[1]);if(!Array.isArray(replies))continue;
        for(const reply of replies){const id=JSON.parse(reply.questionItemId);if(Array.isArray(id)&&id[0]==='request_user_input_async'&&typeof id[1]==='string'&&Number.isInteger(id[2]))result.add(JSON.stringify(id));}
      }catch{}
    }
  }
  return result;
}
function pendingFromItems(items){
  const asked=new Set(),answered=new Set();
  for(const item of items){let value;try{value=JSON.parse(item.item_json);}catch{continue;}
    if(item.item_type==='agentMessage'&&Array.isArray(value.questions))value.questions.forEach((q,i)=>asked.add(JSON.stringify(['request_user_input_async',value.id||item.item_id,i])));
    if(item.item_type==='userMessage')for(const id of answerIds(value.content))answered.add(id);
  }
  return [...asked].filter(id=>!answered.has(id));
}
module.exports={answerIds,pendingFromItems};
