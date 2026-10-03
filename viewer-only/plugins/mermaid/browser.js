import mermaid from 'mermaid';

// All assets are bundled. Diagrams cannot lower these application settings.
const locked = {
  startOnLoad: false,
  securityLevel: 'strict',
  suppressErrorRendering: true,
  maxTextSize: 65536,
  maxEdges: 500,
  htmlLabels: false,
  theme: 'default',
  themeCSS: '',
  fontFamily: 'Arial, sans-serif',
};
mermaid.initialize({ ...locked, secure: ['secure', ...Object.keys(locked)] });

window.renderMermaid = async request => {
  try {
    if (request.protocol !== 1 || request.language !== 'mermaid' ||
        typeof request.source !== 'string' || request.source.length > 65536 ||
        request.width !== 900) {
      throw new Error('Invalid diagram request');
    }
    // This plugin accepts diagram notation, not per-document renderer settings.
    if (/^\s*---(?:\r?\n|$)/.test(request.source) || /%%\s*\{/.test(request.source)) {
      throw new Error('Diagram configuration directives are disabled');
    }
    const { svg } = await mermaid.render('reader-diagram', request.source);
    const doc = new DOMParser().parseFromString(svg, 'image/svg+xml');
    if (doc.querySelector('parsererror') || doc.documentElement.localName !== 'svg') {
      throw new Error('Invalid SVG returned by Mermaid');
    }
    // Vector output must remain inert even if exported to another SVG viewer.
    for (const el of doc.querySelectorAll('*')) {
      if (['script', 'foreignObject', 'iframe', 'image', 'use', 'a'].includes(el.localName)) {
        if (el.localName === 'a') el.replaceWith(...el.childNodes);
        else el.remove();
        continue;
      }
      for (const attr of [...el.attributes]) {
        if (/^on/i.test(attr.name) || ['href', 'xlink:href'].includes(attr.name)) {
          el.removeAttribute(attr.name);
        }
      }
      const css = el.localName === 'style' ? el.textContent : (el.getAttribute('style') || '');
      if (/@import|@font-face|\\/i.test(css)) throw new Error('External diagram styles are disabled');
      for (const match of css.matchAll(/url\(([^)]*)\)/gi)) {
        const target = match[1].trim().replace(/^['"]|['"]$/g, '');
        if (!/^#[a-zA-Z0-9_.:-]+$/.test(target)) throw new Error('External diagram resources are disabled');
      }
    }
    const element = document.importNode(doc.documentElement, true);
    const viewBox = element.viewBox.baseVal;
    if (!(viewBox.width > 0 && viewBox.height > 0)) throw new Error('Diagram has no bounds');
    const width = Math.max(1, Math.ceil(Math.min(request.width, viewBox.width)));
    const height = Math.max(1, Math.ceil(viewBox.height * width / viewBox.width));
    if (height > 4096 || width * height > 4000000) throw new Error('Diagram exceeds display bounds');
    element.setAttribute('width', String(width));
    element.setAttribute('height', String(height));
    element.style.maxWidth = 'none';
    document.body.replaceChildren(element);
    await document.fonts.ready;
    // Offscreen WebKit can suspend animation frames. Synchronous layout plus
    // createPDF's completion callback is the rendering boundary here.
    element.getBoundingClientRect();
    const safeSVG = new XMLSerializer().serializeToString(element);
    window.webkit.messageHandlers.result.postMessage({ svg: safeSVG, width, height });
  } catch (error) {
    window.webkit.messageHandlers.result.postMessage({ error: String(error.message || error).slice(0,512) });
  }
};
