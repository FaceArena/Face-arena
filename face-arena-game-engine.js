(function(root,factory){
  const api=factory();
  if(typeof module==="object"&&module.exports)module.exports=api;
  if(root)root.FaceArenaGameEngine=api;
})(typeof globalThis!=="undefined"?globalThis:this,function(){
  "use strict";
  const ACTIVE=new Set(["queued","matched","confirmed","voting","champion"]);
  const DEMO_ID=/^(demo[_-]|mock[_-]|bot[_-])/i;
  const idEq=(a,b)=>String(a)===String(b);
  const clone=x=>JSON.parse(JSON.stringify(x));
  function normalizeQueue(photos){
    const list=photos.map((p,index)=>({...p,_queueOrder:Number.isFinite(p._queueOrder)?p._queueOrder:index}));
    let next=list.reduce((m,p)=>Math.max(m,p._queueOrder),-1)+1;
    list.forEach(p=>{if(p.status==="queued"&&!Number.isFinite(p.queueSeq))p.queueSeq=next++});
    return list;
  }
  function queueCompare(a,b){
    const at=Number(a.queuedAt)||0,bt=Number(b.queuedAt)||0;
    if(at!==bt)return at-bt;
    const as=Number.isFinite(a.queueSeq)?a.queueSeq:Number(a._queueOrder)||0;
    const bs=Number.isFinite(b.queueSeq)?b.queueSeq:Number(b._queueOrder)||0;
    return as-bs;
  }
  function activeForOwner(photos,photo){
    const owner=photo.userId??photo.ownerId??"__local_user__";
    return photos.filter(p=>ACTIVE.has(p.status)&&(p.userId??p.ownerId??"__local_user__")===owner).length;
  }
  function laneReady(lane){
    if(!lane||(lane.demoShowcase&&lane.stage!=="done")||lane.userPhotoId)return false;
    if(lane.stage==="w"||lane.stage==="v")return !!lane.isMock;
    return lane.stage==="empty"||lane.stage==="done"||lane.stage==="cancelled"||lane.stage==null;
  }
  function selectNextAssignment(photos,lanes){
    const ordered=normalizeQueue(photos).filter(p=>p.status==="queued"&&activeForOwner(photos,p)<=3).sort(queueCompare);
    const occupied=new Set(),reservedLanes=new Set();
    lanes.forEach(l=>{if(l.userPhotoId!=null)occupied.add(String(l.userPhotoId));if(l.championPhotoId!=null)occupied.add(String(l.championPhotoId))});
    photos.forEach(p=>{if(p.status==="matched"&&p.targetLaneId!=null)reservedLanes.add(String(p.targetLaneId))});
    const photo=ordered.find(p=>!occupied.has(String(p.id)));
    if(!photo)return null;
    const lane=[...lanes].filter(l=>Number(l.id)>=1&&Number(l.id)<=10&&laneReady(l)&&!reservedLanes.has(String(l.id))).sort((a,b)=>Number(a.id)-Number(b.id))[0];
    return lane?{photoId:photo.id,laneId:lane.id}:null;
  }
  function assignChallenger(state,assignment,battleUid,now){
    const next=clone(state),p=next.photos.find(x=>idEq(x.id,assignment.photoId)),lane=next.lanes.find(x=>idEq(x.id,assignment.laneId));
    if(!p||p.status!=="queued"||!lane||!laneReady(lane)||activeForOwner(next.photos,p)>3)return {state,assigned:false,reason:"ineligible"};
    if(next.lanes.some(l=>idEq(l.userPhotoId,p.id)||idEq(l.championPhotoId,p.id)))return {state,assigned:false,reason:"duplicate"};
    p.status="confirmed";p.battleId=lane.id;p.battleUid=battleUid;p.side=lane.championSide? (lane.championSide==="R"?"B":"R") : (p.side||"R");
    p.matchDeadline=null;p.matchedAt=now;
    lane.userPhotoId=p.id;lane.battleUid=battleUid;lane.stage="w";lane.stageStarted=now;lane.stageEnd=now+150000;lane.redVotes=0;lane.blueVotes=0;lane._finalized=false;lane.isMock=false;
    if(lane.championPhotoId){p.opponentName=lane.championName;p.opponentImg=lane.championImg}
    if(p.side==="R"){lane.redName="you";lane.blueName=(p.opponentName||"opponent").replace("@","")}
    else{lane.blueName="you";lane.redName=(p.opponentName||"opponent").replace("@","")}
    return {state:next,assigned:true,photoId:p.id,laneId:lane.id};
  }
  function resolveBattle(state,laneId,now){
    const next=clone(state),lane=next.lanes.find(x=>idEq(x.id,laneId));
    if(!lane||lane._finalized||lane.stage!=="v")return {state,changed:false,result:null};
    const p=next.photos.find(x=>idEq(x.id,lane.userPhotoId));
    const uid=lane.battleUid;
    if(!p)return {state,changed:false,result:null};
    const mine=p.side==="R"?Number(lane.redVotes)||0:Number(lane.blueVotes)||0;
    const theirs=p.side==="R"?Number(lane.blueVotes)||0:Number(lane.redVotes)||0;
    const outcome=mine>theirs?"win":mine<theirs?"lose":"draw";
    const stats=next.participantStats||(next.participantStats={});
    const st=stats[String(p.id)]||(stats[String(p.id)]={wins:0,losses:0,defenses:0,currentStreak:0,bestStreak:0,name:p.name||"Участник",img:p.dataUrl||"",isChampion:false,laneId:null});
    const oldId=lane.championPhotoId,wasChampion=oldId!=null&&idEq(oldId,p.id);
    const completed=[];
    if(outcome==="win"){
      st.wins=(st.wins||0)+1;st.currentStreak=(st.currentStreak||0)+1;st.bestStreak=Math.max(st.bestStreak||0,st.currentStreak);
      if(wasChampion)st.defenses=(st.defenses||0)+1;
      else if(oldId!=null){
        const old=next.photos.find(x=>idEq(x.id,oldId));
        if(old){old.status="completed";old.result="lose";old.completedAt=now;old.battleId=null;old.battleUid=uid;completed.push(old.id)}
        const oldStats=stats[String(oldId)]||(stats[String(oldId)]={wins:0,losses:0,defenses:0,currentStreak:0,bestStreak:0,name:old&&old.name||"Участник",img:old&&old.dataUrl||"",isChampion:false,laneId:null});
        oldStats.isChampion=false;oldStats.laneId=null;oldStats.losses=(oldStats.losses||0)+1;oldStats.currentStreak=0;
        if(old&&!next.history.some(h=>String(h.battleUid)===String(uid)&&idEq(h.photoId,old.id))){
          next.history.unshift({photoId:old.id,battleId:lane.id,battleUid:uid,laneId:lane.id,side:old.side,result:"lose",myVotes:theirs,oppVotes:mine,opponentName:p.name||"Участник",opponentImg:p.dataUrl||"",completedAt:now,myImg:old.dataUrl||"",championAfter:false});
        }
      }
      lane.championPhotoId=p.id;lane.championSide=p.side;lane.championName=st.name;lane.championImg=p.dataUrl;lane.championStreak=st.currentStreak;
      st.isChampion=true;st.laneId=lane.id;p.status="champion";p.completedAt=null;p.result="win";p.battleId=lane.id;
    }else if(outcome==="lose"){
      st.losses=(st.losses||0)+1;st.currentStreak=0;
      p.status="completed";p.result=outcome;p.completedAt=now;p.battleId=null;completed.push(p.id);
      if(wasChampion){lane.championPhotoId=null;lane.championSide=null;lane.championName=null;lane.championImg=null;lane.championStreak=0;st.isChampion=false;st.laneId=null}
    }else if(wasChampion){
      p.status="champion";p.result="draw";p.completedAt=null;p.battleId=lane.id;
    }else{
      p.status="completed";p.result="draw";p.completedAt=now;p.battleId=null;completed.push(p.id);
    }
    if(!next.history)next.history=[];
    if(!next.history.some(h=>String(h.battleUid)===String(uid)&&idEq(h.photoId,p.id))){
      next.history.unshift({photoId:p.id,battleId:lane.id,battleUid:uid,laneId:lane.id,side:p.side,result:outcome,myVotes:mine,oppVotes:theirs,opponentName:p.opponentName,opponentImg:p.opponentImg,completedAt:now,myImg:p.dataUrl,championAfter:p.status==="champion"});
    }
    lane.userPhotoId=null;lane.stage="done";lane._finalized=true;lane.redVotes=0;lane.blueVotes=0;
    return {state:next,changed:true,result:{laneId:lane.id,battleUid:uid,outcome,winnerSide:outcome==="win"?p.side:outcome==="lose"?(p.side==="R"?"B":"R"):"draw",championPhotoId:lane.championPhotoId,completedPhotoIds:completed,wasChampion}};
  }
  function cancelBattle(state,laneId,now){
    const next=clone(state),lane=next.lanes.find(x=>idEq(x.id,laneId));
    if(!lane||lane._finalized||!(lane.stage==="w"||lane.stage==="v"))return {state,changed:false};
    const p=next.photos.find(x=>idEq(x.id,lane.userPhotoId));
    if(p){
      // If another participant is already waiting, let FIFO advance and archive
      // the timed-out entry. If nobody is waiting, keep this photo queued.
      const hasNextQueued=next.photos.some(x=>!idEq(x.id,p.id)&&x.status==="queued");
      p.status=hasNextQueued?"cancelled":"queued";
      p.battleId=null;p.battleUid=null;p.targetLaneId=null;
      p.matchedAt=null;p.matchDeadline=null;p.completedAt=null;
      p.side=null;p.opponentName=null;p.opponentImg=null;
    }
    // Release the lane but preserve its incumbent champion.
    lane.userPhotoId=null;lane.stage="done";lane._finalized=true;
    lane.redVotes=0;lane.blueVotes=0;
    return {state:next,changed:true};
  }
  function buildRanking(participantStats,photos){
    return Object.keys(participantStats||{}).filter(id=>!DEMO_ID.test(id)).map(id=>{
      const s=participantStats[id]||{},p=(photos||[]).find(x=>idEq(x.id,id));
      if(s.isDemo||s.demoOnly||p&&(p.isDemo||p.demoOnly))return null;
      return {id,name:s.name||"Участник",img:s.img||(p&&p.dataUrl)||"",wins:s.wins||0,losses:s.losses||0,defenses:s.defenses||0,streak:s.currentStreak||0,best:s.bestStreak||0,isChampion:!!s.isChampion||!!(p&&p.status==="champion"),laneId:s.laneId||null};
    }).filter(Boolean).sort((a,b)=>Number(b.isChampion)-Number(a.isChampion)||b.defenses-a.defenses||b.wins-a.wins||b.streak-a.streak||String(a.id).localeCompare(String(b.id)));
  }
  return {normalizeQueue,selectNextAssignment,assignChallenger,resolveBattle,cancelBattle,buildRanking};
});
