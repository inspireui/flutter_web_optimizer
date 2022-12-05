String dartAgencyBuild = '''
    var split = window.location.pathname.split('/');
    if (split.length > 2 && split[2] == 'extension') {
      var link = document.createElement('link');
      link.rel = 'preload';
      link.as = 'fetch';
      link.crossOrigin = 'anonymous';
      document.head.appendChild(link);
      link.href = window.location.origin + '/extensions/product?id=' + split[1] + '&host=' + document.referrer;
    } else if (split.length > 1) {
      var link = document.createElement('link');
      link.rel = 'preload';
      link.as = 'fetch';
      link.crossOrigin = 'anonymous';
      document.head.appendChild(link);
      link.href = window.location.origin + '/agency?id=' + split[1];
    }
''';