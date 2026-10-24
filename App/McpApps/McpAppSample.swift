// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
  import Foundation
  import MonoAgentKit

  /// Synthetic, inline-only app, used by automated WK tests and future DEBUG composition.
  /// No catalog/transcript route is installed in PR1.
  enum McpGardenFixture {
    static let html = """
      <!doctype html><html><head><meta name="viewport" content="width=device-width"></head>
      <style>body{font:13px -apple-system,system-ui,sans-serif;margin:16px;color:#202520;background:#fff}
      h1{font-size:18px}button{font:12px -apple-system;min-height:44px;margin:3px;padding:8px;border:1px solid #b7c7bf;border-radius:8px;background:#eef6f1;color:#24725f}</style>
      <body><h1>Garden planner (synthetic)</h1><p id="status">Preparing three garden beds</p>
      <button onclick="request('tools/call',{name:'plan',arguments:{beds:3}})">Plan beds</button>
      <button onclick="request('resources/read',{uri:'garden://beds'})">Read beds</button>
      <button onclick="request('ui/open-link',{url:'https://garden.example/guide'})">Open guide</button>
      <button onclick="request('ui/update-model-context',{structuredContent:{beds:3}})">Prepare context</button>
      <button onclick="notify('ui/notifications/size-changed',{height:700})">Resize app</button>
      <button onclick="notify('ui/notifications/request-teardown',{})">Close app</button>
      <script>
      let next = 1, acknowledgeTeardown = true;
      const methods = new Map();
      const applyContext = context => {
        if (context?.theme) {
          document.body.style.background = context.theme === 'dark' ? '#1d221e' : '#ffffff';
          document.body.style.color = context.theme === 'dark' ? '#e7e8e4' : '#202520';
        }
      };
      const send = rpc => parent.postMessage(rpc, '*');
      const notify = (method,params) => send({jsonrpc:'2.0',method,params});
      const request = (method,params) => {const id='garden-'+next++;methods.set(id,method);send({jsonrpc:'2.0',id,method,params});};
      const observe = value => notify('fixture/observed',value);
      addEventListener('message', event => {
        if (event.source !== parent || event.data?.jsonrpc !== '2.0') return;
        const rpc = event.data;
        if (rpc.method === 'fixture/command') {
          if (rpc.params.navigate) { location.href = 'about:blank'; return; }
          if (rpc.params.rpc) send(rpc.params.rpc);
          if (rpc.params.batch) for (const item of rpc.params.batch) send(item);
          if ('acknowledgeTeardown' in rpc.params) acknowledgeTeardown = rpc.params.acknowledgeTeardown;
          return;
        }
        if (rpc.method === 'ui/resource-teardown') {
          observe({kind:'teardown',rpc});
          if (acknowledgeTeardown) send({jsonrpc:'2.0',id:rpc.id,result:{}});
          return;
        }
        if (!rpc.method) {
          observe({kind:'response',rpc});
          if (rpc.id === 'initialize' && rpc.result) {applyContext(rpc.result.hostContext);notify('ui/notifications/initialized',{});}
          if (methods.has(rpc.id)) {
            document.getElementById('status').textContent = rpc.error ? 'Request declined' : 'Request complete';
            methods.delete(rpc.id);
          }
          return;
        }
        if (rpc.method === 'ui/notifications/host-context-changed') applyContext(rpc.params);
        observe({kind:'notification',rpc});
        if (rpc.method === 'ui/notifications/tool-result') document.getElementById('status').textContent = 'Garden planner ready';
      });
      addEventListener('load', () => setTimeout(() => send({jsonrpc:'2.0',id:'initialize',method:'ui/initialize',
        params:{appInfo:{name:'Garden planner',version:'1.0'},appCapabilities:{},protocolVersion:'2026-01-26'}}),0));
      </script></body></html>
      """
    static func resource(toolResult: JSONValue? = nil) throws -> ApiMcpAppResource {
      let app: JSONValue = .object([
        "type": .string("mcp_app"), "id": .string("garden"),
        "invocationId": .string("garden-invocation"),
        "connectionId": .string("garden-connection"), "serverName": .string("garden"),
        "toolName": .string("plan"),
        "resourceUri": .string("ui://garden/planner"),
        "mediaType": .string("text/html;profile=mcp-app"),
        "protocolVersion": .string("2026-01-26"), "title": .string("Garden planner (synthetic)"),
      ])
      let value: JSONValue = .object([
        "app": app, "html": .string(html), "connected": .bool(true),
        "toolInput": .object(["beds": .number(3)]),
        "toolResult": toolResult
          ?? .object([
            "content": .array([
              .object(["type": .string("text"), "text": .string("Three beds ready")])
            ])
          ]),
      ])
      return try JSONDecoder().decode(ApiMcpAppResource.self, from: JSONEncoder().encode(value))
    }
  }
#endif
