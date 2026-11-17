/* FACE ARENA Audio Engine — hybrid UI/game SFX, no external audio assets. */
(function(){
  "use strict";
  const STORAGE_KEY="face_arena_audio_v1";
  const DEFAULTS={enabled:true,volume:65};
  let settings={...DEFAULTS};
  let context=null,master=null,unlocked=false;
  const lastPlayed=new Map();
  const COOLDOWN={click:45,switch:90,impact:180,error:180,matchFound:350,votingStart:500,countdown:700,voteSuccess:180,victory:500,defeat:500,champion:700,titleLost:700};
  try{
    const saved=JSON.parse(localStorage.getItem(STORAGE_KEY)||"null");
    if(saved&&typeof saved==="object"){
      settings.enabled=saved.enabled!==false;
      settings.volume=Math.max(0,Math.min(100,Number.isFinite(Number(saved.volume))?Number(saved.volume):DEFAULTS.volume));
    }
  }catch(_){}

  function persist(){
    try{localStorage.setItem(STORAGE_KEY,JSON.stringify(settings));}catch(_){}
  }
  function getContext(){
    if(context)return context;
    const Ctx=window.AudioContext||window.webkitAudioContext;
    if(!Ctx)return null;
    try{
      context=new Ctx();
      master=context.createGain();
      master.gain.value=settings.enabled?settings.volume/100:0;
      master.connect(context.destination);
      return context;
    }catch(_){return null}
  }
  function unlock(){
    const ctx=getContext();
    if(!ctx)return Promise.resolve(false);
    if(ctx.state==="running"){unlocked=true;return Promise.resolve(true)}
    try{
      // Call resume synchronously inside the user's pointer/key gesture (important on iOS Safari).
      const resumed=ctx.resume();
      return Promise.resolve(resumed).then(()=>{unlocked=ctx.state==="running";return unlocked}).catch(()=>false);
    }catch(_){return Promise.resolve(false)}
  }
  function setEnabled(value){
    settings.enabled=!!value;
    if(master&&context)master.gain.setTargetAtTime(settings.enabled?settings.volume/100:0,context.currentTime,.025);
    persist();
  }
  function setVolume(value){
    settings.volume=Math.max(0,Math.min(100,Number(value)||0));
    if(master&&context)master.gain.setTargetAtTime(settings.enabled?settings.volume/100:0,context.currentTime,.025);
    persist();
  }
  function tone(freq,start,duration,wave,gain,slide){
    const osc=context.createOscillator(),amp=context.createGain();
    osc.type=wave||"sine";
    osc.frequency.setValueAtTime(freq,start);
    if(slide)osc.frequency.exponentialRampToValueAtTime(Math.max(25,slide),start+duration);
    amp.gain.setValueAtTime(.0001,start);
    amp.gain.exponentialRampToValueAtTime(Math.max(.0002,gain),start+.012);
    amp.gain.exponentialRampToValueAtTime(.0001,start+duration);
    osc.connect(amp);amp.connect(master);
    osc.start(start);osc.stop(start+duration+.025);
  }
  const recipes={
    click(ctx){tone(720,ctx.currentTime,.065,"sine",.16,520)},
    switch(ctx){tone(510,ctx.currentTime,.075,"sine",.14,760)},
    impact(ctx){tone(125,ctx.currentTime,.19,"triangle",.32,48);tone(680,ctx.currentTime+.012,.075,"sine",.12,240)},
    error(ctx){tone(210,ctx.currentTime,.14,"triangle",.22,145);tone(155,ctx.currentTime+.09,.15,"sine",.16,115)},
    matchFound(ctx){tone(560,ctx.currentTime,.10,"sine",.17,760);tone(820,ctx.currentTime+.105,.13,"sine",.18,1040)},
    votingStart(ctx){tone(170,ctx.currentTime,.20,"triangle",.27,70);tone(520,ctx.currentTime+.035,.10,"sine",.14,680)},
    countdown(ctx){tone(390,ctx.currentTime,.075,"sine",.17,330)},
    voteSuccess(ctx){tone(660,ctx.currentTime,.075,"sine",.15,790);tone(990,ctx.currentTime+.085,.10,"sine",.17,1180)},
    victory(ctx){tone(523.25,ctx.currentTime,.16,"sine",.16,659.25);tone(659.25,ctx.currentTime+.12,.17,"sine",.18,783.99);tone(783.99,ctx.currentTime+.25,.24,"sine",.20,1046.5)},
    defeat(ctx){tone(330,ctx.currentTime,.16,"triangle",.18,247);tone(247,ctx.currentTime+.14,.23,"triangle",.19,165)},
    champion(ctx){tone(523.25,ctx.currentTime,.17,"sine",.17,659.25);tone(783.99,ctx.currentTime+.13,.18,"sine",.19,987.77);tone(1046.5,ctx.currentTime+.27,.30,"sine",.21,1318.5)},
    titleLost(ctx){tone(440,ctx.currentTime,.16,"triangle",.18,330);tone(294,ctx.currentTime+.14,.20,"triangle",.19,196);tone(196,ctx.currentTime+.30,.24,"sine",.15,130)}
  };
  function play(name,force){
    if(!force&&(!settings.enabled||settings.volume===0))return false;
    const now=Date.now(),cooldown=COOLDOWN[name]||100;
    if(!force&&now-(lastPlayed.get(name)||0)<cooldown)return false;
    const ctx=getContext();
    if(!ctx||ctx.state!=="running")return false;
    const recipe=recipes[name];
    if(!recipe)return false;
    lastPlayed.set(name,now);
    try{recipe(ctx);return true}catch(_){return false}
  }
  function preview(){
    if(!settings.enabled||settings.volume===0)return Promise.resolve(false);
    // Resume is invoked directly by the preview button's click handler, before any await.
    return unlock().then(ok=>{
      if(!ok)return false;
      play("click",true);
      setTimeout(()=>play("switch",true),150);
      setTimeout(()=>play("impact",true),360);
      return true;
    });
  }
  document.addEventListener("pointerdown",unlock,{once:true,passive:true});
  document.addEventListener("keydown",unlock,{once:true});
  document.addEventListener("click",function(event){
    const target=event.target&&event.target.closest?event.target.closest("button,[role='button'],.card,.menu-item"):null;
    if(!target||target.id==="soundPreview"||target.id==="togSound")return;
    if(target.classList.contains("btn-gear")||target.closest(".tabs"))play("switch");
    else if(target.classList.contains("card"))play("impact");
    else play("click");
  },true);
  window.FaceArenaAudio={
    play,
    preview,
    unlock,
    getSettings(){return {...settings}},
    setEnabled,
    setVolume
  };
})();