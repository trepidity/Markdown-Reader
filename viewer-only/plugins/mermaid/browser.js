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

let renders = 0; // Mermaid needs a fresh element id per call when one page renders a batch.
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
    const { svg } = await mermaid.render(`reader-diagram-${renders++}`, request.source);
    const doc = new DOMParser().parseFromString(svg, 'image/svg+xml');
    if (doc.querySelector('parsererror') || doc.documentElement.localName !== 'svg') {
      throw new Error('Invalid SVG returned by Mermaid');
    }
    // Vector output must remain inert even if exported to another SVG viewer.
    const blocked = new Set(['script', 'foreignobject', 'iframe', 'image', 'use', 'a', 'object', 'embed', 'link', 'meta', 'base',
      'audio', 'video', 'animate', 'animatemotion', 'animatetransform', 'set', 'feimage', 'handler', 'listener', 'canvas']);
    // Any value that could fetch or run something: a URL that is not a same-document #fragment, or a script URL.
    const external = value => {
      if (/(?:^|[^a-z])(?:javascript|vbscript|data):/i.test(value) || /@import|expression\s*\(|-moz-binding|behavior\s*:/i.test(value)) return true;
      // CSS functions that load a resource without url(): image-set("a.png"), src("a.png"), cross-fade(), element().
      if (/(?:^|[^a-z-])(?:image-set|-webkit-image-set|src|cross-fade|-webkit-cross-fade|element)\s*\(/i.test(value)) return true;
      for (const match of value.matchAll(/url\(([^)]*)\)/gi)) {
        const target = match[1].trim().replace(/^['"]|['"]$/g, '');
        if (!/^#[a-zA-Z0-9_.:-]+$/.test(target)) return true;
      }
      return false;
    };
    for (const el of doc.querySelectorAll('*')) {
      if (blocked.has(el.localName.toLowerCase())) {
        if (el.localName === 'a') el.replaceWith(...el.childNodes);
        else el.remove();
        continue;
      }
      for (const attr of [...el.attributes]) {
        if (/^on/i.test(attr.name) || ['href', 'xlink:href', 'src', 'data', 'action', 'formaction'].includes(attr.name.toLowerCase())) {
          el.removeAttribute(attr.name);
        } else if (attr.name.toLowerCase() === 'style' && /\\/.test(attr.value)) {
          throw new Error('External diagram styles are disabled'); // CSS escapes can hide any of the above
        } else if (external(attr.value)) {
          // Presentation attributes (fill, filter, mask, clip-path, marker-*, style...) share the rule.
          throw new Error('External diagram resources are disabled');
        }
      }
      const css = el.localName === 'style' ? el.textContent : '';
      if (/@font-face|\\/.test(css) || external(css)) throw new Error('External diagram styles are disabled');
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
