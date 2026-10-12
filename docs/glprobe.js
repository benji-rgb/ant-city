// debug: count WebGL resources / uploads, log every 10 s, log context loss
(function(){
  var S = {tex:0, texDel:0, buf:0, bufDel:0, fb:0, rb:0, prog:0, texImg:0, texImgBytes:0, texSub:0, texSubBytes:0, bufData:0, bufBytes:0, lost:0};
  function wrap(proto){
    function w(name, f){ var o = proto[name]; if(!o) return; proto[name] = function(){ f.apply(this, arguments); return o.apply(this, arguments); }; }
    w('createTexture', function(){S.tex++;}); w('deleteTexture', function(t){ if(t) S.texDel++;});
    w('createBuffer', function(){S.buf++;}); w('deleteBuffer', function(b){ if(b) S.bufDel++;});
    w('createFramebuffer', function(){S.fb++;}); w('deleteFramebuffer', function(f){ if(f) S.fbDel=(S.fbDel||0)+1; }); w('createRenderbuffer', function(){S.rb++;}); w('createProgram', function(){S.prog++;});
    w('texImage2D', function(){ S.texImg++; var a=arguments; if(a.length>=9 && typeof a[3]=='number') S.texImgBytes += a[3]*a[4]*4; });
    w('texSubImage2D', function(){ S.texSub++; var a=arguments; if(a.length>=9 && typeof a[4]=='number') S.texSubBytes += a[4]*a[5]*4; });
    w('bufferData', function(){ S.bufData++; var a=arguments; if (typeof a[1]=='number') S.bufBytes += a[1]; else if (a.length>=5 && typeof a[4]=='number') S.bufBytes += a[4]; else if (a[1] && a[1].byteLength) S.bufBytes += a[1].byteLength; });
    w('bufferSubData', function(){ S.bufSub=(S.bufSub||0)+1; });
  }
  if (window.WebGL2RenderingContext) wrap(WebGL2RenderingContext.prototype);
  if (window.WebGLRenderingContext) wrap(WebGLRenderingContext.prototype);
  var t0 = Date.now();
  setInterval(function(){
    console.log('GLPROBE t=' + Math.round((Date.now()-t0)/1000) + ' liveTex=' + (S.tex-S.texDel) + ' texCreated=' + S.tex + ' liveBuf=' + (S.buf-S.bufDel) + ' bufCreated=' + S.buf +
      ' fb=' + S.fb + ' fbLive=' + (S.fb-(S.fbDel||0)) + ' prog=' + S.prog + ' texImage2D=' + S.texImg + ' texImgMB=' + (S.texImgBytes/1048576).toFixed(1) + ' texSub=' + S.texSub + ' texSubMB=' + (S.texSubBytes/1048576).toFixed(1) +
      ' bufSub=' + (S.bufSub||0) + ' bufferData=' + S.bufData + ' bufMB=' + (S.bufBytes/1048576).toFixed(1) + ' lost=' + S.lost + ' dpr=' + window.devicePixelRatio);
  }, 10000);
  document.addEventListener('webglcontextlost', function(){ S.lost++; console.log('GLPROBE CONTEXT LOST'); }, true);
})();
// debug: ?losetest -> force a context loss after 25 s (WEBGL_lose_context)
if (location.search.indexOf('losetest') >= 0) setTimeout(function(){
  var c = document.getElementById('canvas'); var gl = c && (c.getContext('webgl2') || c.getContext('webgl'));
  var ext = gl && gl.getExtension('WEBGL_lose_context'); console.log('GLPROBE forcing context loss ' + !!ext); if (ext) ext.loseContext();
}, 25000);
