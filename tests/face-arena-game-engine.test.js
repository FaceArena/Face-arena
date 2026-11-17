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
 assert.deepEqual(E.selectNextAssignment([photo("b",2),photo("a",1)],[lane(2),lane(1)]),{photoId:"a",laneId:1});
});
test("no free lane returns null",()=>{
 assert.equal(E.selectNextAssignment([photo("a")],[lane(1,{stage:"w",isMock:false,userPhotoId:"x"})]),null);
});
test("mock demo lane can be claimed but showcase lane cannot",()=>{
 assert.deepEqual(E.selectNextAssignment([photo("a")],[lane(1,{stage:"v",isMock:true}),lane(2,{stage:"v",isMock:true,demoShowcase:true})]),{photoId:"a",laneId:1});
});
test("duplicate photo assignment is rejected without mutation",()=>{
 const state={photos:[photo("x")],lanes:[lane(1,{userPhotoId:"x",stage:"w"})],history:[],participantStats:{}};
 const r=E.assignChallenger(state,{photoId:"x",laneId:1},"b1",100);
 assert.equal(r.assigned,false);assert.equal(state.photos[0].status,"queued");
});
test("three active photo cap is enforced",()=>{
 const state={photos:[{id:"1",status:"champion"},{id:"2",status:"queued"},{id:"3",status:"voting"},{id:"4",status:"queued"}],lanes:[lane(1)],history:[],participantStats:{}};
 assert.equal(E.assignChallenger(state,{photoId:"4",laneId:1},"b",1).assigned,false);
});
test("assignment preserves string IDs and starts battle",()=>{
 const state={photos:[photo("photo-abc")],lanes:[lane(1)],history:[],participantStats:{}};
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
test("draw completes challenger without changing title",()=>{
 const state={photos:[{id:"p",status:"voting",side:"B"}],lanes:[lane(1,{stage:"v",userPhotoId:"p",championPhotoId:"c",championSide:"R",battleUid:"b",redVotes:2,blueVotes:2})],history:[],participantStats:{}};
 const r=E.resolveBattle(state,1,100);assert.equal(r.state.lanes[0].championPhotoId,"c");assert.equal(r.state.photos[0].result,"draw");
});
test("ranking excludes demo identities and has deterministic ID tie break",()=>{
 const rows=E.buildRanking({demo_alex:{wins:99},"z-user":{wins:2},"a-user":{wins:2}},[]);
 assert.deepEqual(rows.map(x=>x.id),["a-user","z-user"]);
});
