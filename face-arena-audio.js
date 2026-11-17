/* FACE ARENA Audio Engine — hybrid UI/game SFX, no external audio assets. */
(function(){
  "use strict";
  const STORAGE_KEY="face_arena_audio_v1";
  const DEFAULTS={enabled:true,volume:65};
  let settings={...DEFAULTS};
  let context=null,master=null,unlocked=false;
  const lastPlayed=new Map();
  const COOLDOWN={click:45,switch:90,impact:180,error:180};
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
  async function unlock(){
    const ctx=getContext();
    if(!ctx)return false;
    try{if(ctx.state==="suspended")await ctx.resume();unlocked=ctx.state==="running";return unlocked}catch(_){return false}
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
    click(ctx){tone(720,ctx.currentTime,.045,"sine",.055,520)},
    switch(ctx){tone(510,ctx.currentTime,.055,"sine",.045,760)},
    impact(ctx){tone(125,ctx.currentTime,.16,"triangle",.16,48);tone(680,ctx.currentTime+.012,.055,"sine",.035,240)},
    error(ctx){tone(210,ctx.currentTime,.12,"triangle",.09,145);tone(155,ctx.currentTime+.09,.13,"sine",.06,115)}
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
  async function preview(){
    if(!settings.enabled||settings.volume===0)return false;
    const ok=await unlock();
    if(!ok)return false;
    play("click",true);
    setTimeout(()=>play("switch",true),110);
    setTimeout(()=>play("impact",true),260);
    return true;
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