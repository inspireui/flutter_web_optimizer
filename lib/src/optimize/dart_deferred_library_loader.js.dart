const String dartDeferredLibraryLoaderSourceCode = r'''
    // auto-generate, dont edit!!!!!!
    var assetBase = null;
    var jsManifest = null;
    function dartDeferredLibraryLoader(uri, successCallback, errorCallback, loadId) {
      let src;
      try {
        const url = new URL(uri);
        src = uri;
      } catch (e) {
        src = `${assetBase}${uri}`;
      }
      script = document.createElement("script");
      script.type = "text/javascript";
      script.src = src;
      script.addEventListener("load", successCallback, false);
      script.addEventListener("error", errorCallback, false);
      document.body.appendChild(script);
    }
    ''';
