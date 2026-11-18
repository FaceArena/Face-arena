"use strict";
const test=require("node:test");
const assert=require("node:assert/strict");
const E=require("../face-arena-game-engine.js");
const photo=(id,queuedAt=1,extra={})=>({id,status:"queued",queuedAt,...extra});
const lane=(id,extra={})=>({id,stage:"empty",userPhotoId:null,championPhotoId:null,...extra});
test("FIFO sorts by timestamp and stable insertion order for ties",()=>{
 const p=E.normalizeQueue([photo("late",2),photo("first",1),photo("second",1)]);
 const sorted=p.filter(x=>x.status==="queued").sort((a,b)=>a.queuedAt-b.queuedAt||a.queueSeq-b.queueSeq);
 assert.deepEqual(sorted.map(x=>x.id),["first","second","late"]);
});
test("legacy queue order is retained when timestamps tie",()=>{
 const p=E.normalizeQueue([photo("b",5),photo("a",5)]);
 assert.ok(p[0].queueSeq<p[1].queueSeq);
});
test("selects lowest available lane and oldest photo",()=>{
 assert.deepEqual(E.selectNextAssignment([photo("b",2),photo("a",1)],[lane(2,{championPhotoId:"c2"}),lane(1,{championPhotoId:"c1"})]),{photoId:"a",laneId:1});
});
test("no free lane returns null",()=>{
 assert.equal(E.selectNextAssignment([photo("a")],[lane(1,{stage:"w",isMock:false,userPhotoId:"x"})]),null);
});
test("empty and mock lanes are never assigned without a real champion",()=>{
 assert.equal(E.selectNextAssignment([photo("a",1,{userId:"challenger"})],[lane(1),lane(2,{stage:"v",isMock:true}),lane(3,{championPhotoId:"champ"})]).laneId,3);
});
test("skips an empty lane when it cannot form an opening pair and uses the next viable champion lane",()=>{
 const photos=[photo("challenger",1,{userId:"u1"}),{id:"champ",status:"champion",userId:"u2"}];
 const lanes=[lane(1),lane(2,{championPhotoId:"champ"})];
 assert.deepEqual(E.selectNextAssignment(photos,lanes),{photoId:"challenger",laneId:2});
});
test("mock lanes are never selected, even if they appear empty",()=>{
 const photos=[photo("a",1,{userId:"u1"}),photo("b",2,{userId:"u2"})];
 assert.deepEqual(E.selectNextAssignment(photos,[lane(1,{isMock:true}),lane(2)]),{photoId:"a",opponentPhotoId:"b",laneId:2,opening:true});
});
test("new local battles use the 70-second stage timer",()=>{
 const state={photos:[photo("a",1,{userId:"u1"}),photo("b",2,{userId:"u2"})],lanes:[lane(1)],history:[],participantStats:{}};
 const assignment=E.selectNextAssignment(state.photos,state.lanes);
 const result=E.assignChallenger(state,assignment,"timer-test",1000);
 assert.equal(result.state.lanes[0].stageEnd,71000);
});
test("duplicate photo assignment is rejected without mutation",()=>{
 const state={photos:[photo("x")],lanes:[lane(1,{userPhotoId:"x",stage:"w"})],history:[],participantStats:{}};
 const r=E.assignChallenger(state,{photoId:"x",laneId:1},"b1",100);
 assert.equal(r.assigned,false);assert.equal(state.photos[0].status,"queued");
});
test("three active photo cap is enforced",()=>{
 const state={photos:[{id:"1",status:"champion"},{id:"2",status:"queued"},{id:"3",status:"voting"},{id:"4",status:"queued"}],lanes:[lane(1,{championPhotoId:"incumbent"})],history:[],participantStats:{}};
 assert.equal(E.assignChallenger(state,{photoId:"4",laneId:1},"b",1).assigned,false);
});
test("assignment preserves string IDs and starts battle",()=>{
 const state={photos:[photo("photo-abc")],lanes:[lane(1,{championPhotoId:"incumbent"})],history:[],participantStats:{}};
 const r=E.assignChallenger(state,{photoId:"photo-abc",laneId:1},"battle-1",500);
 assert.equal(r.assigned,true);assert.equal(r.state.photos[0].status,"confirmed");assert.equal(r.state.lanes[0].userPhotoId,"photo-abc");
});
test("champion defense increments stats once and is idempotent",()=>{
 const state={photos:[{id:"champ",status:"voting",side:"R",dataUrl:"x"}],lanes:[lane(1,{stage:"v",userPhotoId:"champ",championPhotoId:"champ",championSide:"R",battleUid:"b",redVotes:4,blueVotes:1})],history:[],participantStats:{champ:{wins:1,defenses:0,currentStreak:1,bestStreak:1,isChampion:true}}};
 const r=E.resolveBattle(state,1,999);assert.equal(r.result.outcome,"win");assert.equal(r.state.participantStats.champ.defenses,1);
 assert.equal(E.resolveBattle(r.state,1,1000).changed,false);
});
test("challenger victory archives previous champion and transfers title",()=>{
 const state={photos:[{id:"old",status:"champion",dataUrl:"old"},{id:"new-id",status:"voting",side:"B",dataUrl:"new"}],lanes:[lane(3,{stage:"v",userPhotoId:"new-id",championPhotoId:"old",championSide:"R",battleUid:"b2",redVotes:1,blueVotes:5})],history:[],participantStats:{old:{wins:2,isChampion:true,laneId:3}, "new-id":{}}};
 const r=E.resolveBattle(state,3,100);assert.equal(r.state.lanes[0].championPhotoId,"new-id");assert.equal(r.state.photos[0].status,"completed");assert.equal(r.state.participantStats.old.isChampion,false);
});
test("challenger loss preserves incumbent title",()=>{
 const state={photos:[{id:"new",status:"voting",side:"B",dataUrl:"n"}],lanes:[lane(1,{stage:"v",userPhotoId:"new",championPhotoId:"old",championSide:"R",battleUid:"b",redVotes:4,blueVotes:0})],history:[],participantStats:{}};
 const r=E.resolveBattle(state,1,100);assert.equal(r.state.lanes[0].championPhotoId,"old");assert.equal(r.state.photos[0].status,"completed");
});
test("draw by incumbent keeps champion photo active",()=>{
 const state={photos:[{id:"c",status:"voting",side:"R"}],lanes:[lane(1,{stage:"v",userPhotoId:"c",championPhotoId:"c",championSide:"R",battleUid:"draw-champ",redVotes:2,blueVotes:2})],history:[],participantStats:{c:{isChampion:true,wins:3,defenses:2}}};
 const r=E.resolveBattle(state,1,100);assert.equal(r.state.photos[0].status,"champion");assert.equal(r.state.lanes[0].championPhotoId,"c");
});
test("draw completes challenger without changing title",()=>{
 const state={photos:[{id:"p",status:"voting",side:"B"}],lanes:[lane(1,{stage:"v",userPhotoId:"p",championPhotoId:"c",championSide:"R",battleUid:"b",redVotes:2,blueVotes:2})],history:[],participantStats:{}};
 const r=E.resolveBattle(state,1,100);assert.equal(r.state.lanes[0].championPhotoId,"c");assert.equal(r.state.photos[0].result,"draw");
});
test("ranking excludes demo identities and has deterministic ID tie break",()=>{
 const rows=E.buildRanking({demo_alex:{wins:99},"z-user":{wins:2},"a-user":{wins:2}},[]);
 assert.deepEqual(rows.map(x=>x.id),["a-user","z-user"]);
});

for(const stage of ["w","v"]){
 test("cancelling inactive "+stage+" battle requeues photo and releases lane",()=>{
  const state={
   photos:[{id:"challenger",status:stage==="w"?"confirmed":"voting",queuedAt:10,battleId:2,battleUid:"old-battle",targetLaneId:2,matchedAt:50,side:"B",opponentName:"champ",opponentImg:"champ-img"}],
   lanes:[lane(2,{stage,userPhotoId:"challenger",championPhotoId:"champion",championSide:"R",championName:"champ",championImg:"champ-img",battleUid:"old-battle",redVotes:0,blueVotes:0})],
   history:[],participantStats:{}
  };
  const r=E.cancelBattle(state,2,200);
  assert.equal(r.changed,true);
  const p=r.state.photos[0],l=r.state.lanes[0];
  assert.equal(p.status,"queued");
  assert.equal(p.battleId,null);
  assert.equal(p.battleUid,null);
  assert.equal(p.targetLaneId,null);
  assert.equal(p.side,null);
  assert.equal(l.userPhotoId,null);
  assert.equal(l.stage,"done");
  assert.equal(l.championPhotoId,"champion");
  assert.equal(l.championSide,"R");
  assert.deepEqual(E.selectNextAssignment(r.state.photos,r.state.lanes),{photoId:"challenger",laneId:2});
  // The original state is not mutated.
  assert.equal(state.lanes[0].userPhotoId,"challenger");
 });
}

test("timeout archives the missed participant when another participant is queued",()=>{
 const state={photos:[
  {id:"missed",status:"voting",queuedAt:1,battleId:1,battleUid:"old"},
  {id:"next",status:"queued",queuedAt:2}
 ],lanes:[lane(1,{stage:"v",userPhotoId:"missed",championPhotoId:"incumbent",battleUid:"old"})],history:[],participantStats:{}};
 const r=E.cancelBattle(state,1,200);
 assert.equal(r.state.photos.find(p=>p.id==="missed").status,"cancelled");
 assert.equal(r.state.photos.find(p=>p.id==="next").status,"queued");
 assert.deepEqual(E.selectNextAssignment(r.state.photos,r.state.lanes),{photoId:"next",laneId:1});
});
test("timeout requeues the missed participant when nobody else is queued",()=>{
 const state={photos:[{id:"missed",status:"voting",queuedAt:1,battleId:1,battleUid:"old"}],
  lanes:[lane(1,{stage:"v",userPhotoId:"missed",championPhotoId:"incumbent",battleUid:"old"})],history:[],participantStats:{}};
 const r=E.cancelBattle(state,1,200);
 assert.equal(r.state.photos[0].status,"queued");
 assert.deepEqual(E.selectNextAssignment(r.state.photos,r.state.lanes),{photoId:"missed",laneId:1});
});


test("empty lane pairs the two oldest queued photos from different users",()=>{
 const photos=[photo("a",1,{userId:"u1"}),photo("b",2,{userId:"u2"}),photo("c",3,{userId:"u3"})];
 assert.deepEqual(E.selectNextAssignment(photos,[lane(1)]),{photoId:"a",opponentPhotoId:"b",laneId:1,opening:true});
});
test("empty lane waits rather than matching a user against their own photo",()=>{
 const photos=[photo("a",1,{userId:"u1"}),photo("b",2,{userId:"u1"})];
 assert.equal(E.selectNextAssignment(photos,[lane(1)]),null);
});
test("opening battle assigns two different participants and winner becomes first champion",()=>{
 const state={photos:[photo("a",1,{userId:"u1",dataUrl:"A"}),photo("b",2,{userId:"u2",dataUrl:"B"})],lanes:[lane(1)],history:[],participantStats:{}};
 const assignment=E.selectNextAssignment(state.photos,state.lanes);
 const assigned=E.assignChallenger(state,assignment,"opening-1",100);
 assert.equal(assigned.assigned,true);
 assert.equal(assigned.state.photos[1].status,"confirmed");
 const battle=assigned.state; battle.lanes[0].stage="v";battle.lanes[0].redVotes=7;battle.lanes[0].blueVotes=3;
 const result=E.resolveBattle(battle,1,200);
 assert.equal(result.result.opening,true);
 assert.equal(result.state.lanes[0].championPhotoId,"a");
 assert.equal(result.state.photos.find(x=>x.id==="a").status,"champion");
 assert.equal(result.state.photos.find(x=>x.id==="b").status,"completed");
 assert.equal(result.state.participantStats.a.wins,0);
 assert.equal(result.state.participantStats.a.losses,0);
 assert.equal(result.state.participantStats.a.currentStreak,0);
 assert.equal(result.state.participantStats.b.wins,0);
 assert.equal(result.state.participantStats.b.losses,0);
 assert.equal(result.state.participantStats.b.currentStreak,0);
 assert.equal(result.state.history.length,2);
});
test("opening draw creates no champion and archives both participants",()=>{
 const state={photos:[photo("a",1,{userId:"u1"}),photo("b",2,{userId:"u2"})],lanes:[lane(1)],history:[],participantStats:{}};
 const assigned=E.assignChallenger(state,E.selectNextAssignment(state.photos,state.lanes),"opening-draw",100).state;
 assigned.lanes[0].stage="v";assigned.lanes[0].redVotes=2;assigned.lanes[0].blueVotes=2;
 const result=E.resolveBattle(assigned,1,200);
 assert.equal(result.state.lanes[0].championPhotoId,null);
 assert.equal(result.state.photos.every(x=>x.status==="completed"),true);
});

test("cancelling an opening battle releases both participants together",()=>{
 const state={photos:[
  photo("first",1,{userId:"u1",status:"confirmed",side:"R",battleId:1,battleUid:"opening-cancel"}),
  photo("second",2,{userId:"u2",status:"confirmed",side:"B",battleId:1,battleUid:"opening-cancel"})
 ],lanes:[lane(1,{stage:"w",userPhotoId:"first",openingOpponentPhotoId:"second",battleUid:"opening-cancel"})],history:[],participantStats:{}};
 const r=E.cancelBattle(state,1,500);
 assert.equal(r.changed,true);
 assert.deepEqual(r.state.photos.map(p=>p.status),["queued","queued"]);
 assert.equal(r.state.lanes[0].openingOpponentPhotoId,null);
 assert.deepEqual(E.selectNextAssignment(r.state.photos,r.state.lanes),{photoId:"first",opponentPhotoId:"second",laneId:1,opening:true});
});
