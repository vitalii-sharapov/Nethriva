import RFB from "./noVNC/core/rfb.js";
import * as Spice from "./spice/src/main.js";
import * as SpiceMessages from "./spice/src/spicemsg.js";
import { Constants as SpiceConstants } from "./spice/src/enums.js";

// Native transport keeps API authentication and socket targets outside page-controlled URLs.
const send = value => window.webkit.messageHandlers.vmConsole.postMessage(value);
const channels = new Map();
let viewer, options, stopped = false;
let pendingClipboard = null;
let resizeTimer;
function fitSpice() {
    if (options?.renderer !== "spice") return;
    const screen = document.getElementById("spice-screen");
    const canvas = screen.querySelector("canvas");
    if (!canvas || !canvas.width || !canvas.height) return;
    screen.style.width = canvas.width + "px";
    screen.style.height = canvas.height + "px";
    screen.style.transformOrigin = "top left";
    const scale = options.fit ? Math.min(window.innerWidth / canvas.width, window.innerHeight / canvas.height) : 1;
    screen.style.transform = "scale(" + scale + ")";
}
function resizeSpiceGuest() {
    if (!viewer?.agent_connected || !options.resizeGuest || options.viewOnly) return;
    const width = Math.max(320, Math.min(8192, Math.floor(window.innerWidth / 8) * 8));
    const height = Math.max(200, Math.min(8192, Math.floor(window.innerHeight / 8) * 8));
    viewer.resize_window(0, width, height, 32, 0, 0);
}
new MutationObserver(fitSpice).observe(document.getElementById("spice-screen"), {
    subtree: true, childList: true, attributes: true, attributeFilter: ["width", "height"]
});
const base64 = bytes => {
    let value = "";
    for (let offset = 0; offset < bytes.length; offset += 8192) {
        value += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
    }
    return btoa(value);
};

class NativeSocket {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    constructor(url, protocols) {
        this.id = typeof crypto.randomUUID === "function" ? crypto.randomUUID() :
            "10000000-1000-4000-8000-100000000000".replace(/[018]/g, c =>
                (Number(c) ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> Number(c) / 4).toString(16));
        this.url = "nethriva://console";
        this.protocol = "";
        this.extensions = "";
        this.binaryType = "arraybuffer";
        this.bufferedAmount = 0;
        this.readyState = 0;
        this.onopen = this.onclose = this.onerror = this.onmessage = null;
        this.listeners = new Map();
        channels.set(this.id, this);
        send({ kind: "open", id: this.id });
    }
    addEventListener(name, fn) {
        const values = this.listeners.get(name) || [];
        values.push(fn); this.listeners.set(name, values);
    }
    removeEventListener(name, fn) {
        this.listeners.set(name, (this.listeners.get(name) || []).filter(value => value !== fn));
    }
    dispatch(name, event = {}) {
        this["on" + name]?.(event);
        for (const callback of this.listeners.get(name) || []) callback(event);
    }
    send(data) {
        if (this.readyState !== 1) throw new Error("Console channel is closed");
        const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) :
            ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) :
                new TextEncoder().encode(data);
        this.bufferedAmount += bytes.length;
        for (let offset = 0; offset < bytes.length; offset += 65536) {
            send({ kind: "send", id: this.id, data: base64(bytes.subarray(offset, offset + 65536)) });
        }
    }
    close() {
        if (this.readyState >= 2) return;
        this.readyState = 2;
        send({ kind: "close", id: this.id });
    }
}
window.WebSocket = NativeSocket;

window.nativeConsoleEvent = event => {
    const socket = channels.get(event.id);
    if (!socket) return;
    switch (event.kind) {
        case "open": socket.readyState = 1; socket.dispatch("open"); break;
        case "data": {
            const raw = atob(event.data);
            const bytes = Uint8Array.from(raw, character => character.charCodeAt(0));
            socket.dispatch("message", { data: bytes.buffer });
            break;
        }
        case "sent": socket.bufferedAmount = Math.max(0, socket.bufferedAmount - event.count); break;
        case "close":
            socket.readyState = 3; socket.dispatch("close", { code: 1000, wasClean: true });
            channels.delete(event.id); break;
        case "error":
            socket.readyState = 3; socket.dispatch("error", {});
            socket.dispatch("close", { code: 1006, wasClean: false });
            channels.delete(event.id); break;
    }
};

window.startConsole = configuration => {
    options = configuration;
    stopped = false;
    // noVNC appends its own full-height container to #screen. An empty,
    // visible SPICE container would push that canvas below the viewport.
    document.getElementById("spice-screen").hidden = configuration.renderer !== "spice";
    if (configuration.renderer === "spice") {
        viewer = new Spice.SpiceMainConn({
            uri: "ws://nethriva-console/", screen_id: "spice-screen",
            dump_id: "debug-div", message_id: "message-div",
            password: configuration.password || "",
            onerror: () => { if (!stopped) send({ kind: "failed" }); },
            onagent: function () {
                window.spice_connection = this;
                resizeSpiceGuest();
            }
        });
        // Keep system clipboard access in native code and enforce the user's opt-in.
        viewer.handle_clipboard_grab = function () {
            if (!stopped && options?.clipboard) Spice.SpiceMainConn.prototype.handle_clipboard_grab.call(this);
        };
        viewer.handle_clipboard_receive = function (agentData) {
            if (stopped || !options?.clipboard) return;
            const message = new SpiceMessages.SpiceMsgClipboardReceive(agentData, this.agent_caps);
            if (message.type === SpiceConstants.VD_AGENT_CLIPBOARD_UTF8_TEXT) {
                send({ kind: "clipboard", text: message.get_text() });
            }
        };
        viewer.handle_clipboard_send = function () {
            if (stopped || !options?.clipboard || options.viewOnly || pendingClipboard === null) return;
            const message = new SpiceMessages.SpiceMsgClipboardSend(
                SpiceConstants.VD_AGENT_CLIPBOARD_UTF8_TEXT, pendingClipboard, this.agent_caps);
            this.send_agent_message(SpiceConstants.VD_AGENT_CLIPBOARD, message);
            pendingClipboard = null;
        };
        const timer = setInterval(() => {
            if (stopped || !viewer) { clearInterval(timer); return; }
            if (viewer.display?.state === "ready" && viewer.inputs?.state === "ready") {
                send({ kind: "connected" }); clearInterval(timer);
            }
        }, 200);
    } else {
        viewer = new RFB(document.getElementById("screen"), new NativeSocket(), {
            credentials: {
                ...(configuration.password ? { password: configuration.password } : {}),
                ...(configuration.username ? { username: configuration.username } : {})
            },
            shared: true
        });
        viewer.scaleViewport = configuration.fit;
        viewer.resizeSession = configuration.resizeGuest === true;
        viewer.viewOnly = configuration.viewOnly;
        viewer.addEventListener("connect", () => send({ kind: "connected" }));
        viewer.addEventListener("disconnect", () => { if (!stopped) send({ kind: "failed" }); });
        viewer.addEventListener("securityfailure", () => send({ kind: "failed" }));
        viewer.addEventListener("credentialsrequired", () => send({ kind: "credentialsRequired" }));
        viewer.addEventListener("clipboard", event => {
            if (!stopped && options?.clipboard) send({ kind: "clipboard", text: event.detail.text });
        });
    }
};
window.consoleCredentials = (password, username = "") => {
    if (options.renderer !== "spice") viewer?.sendCredentials({ password, username });
};
window.consoleAction = (action, value) => {
    if (!viewer) return;
    if (action === "cad" && !options.viewOnly) {
        if (options.renderer === "spice") Spice.sendCtrlAltDel(viewer);
        else viewer.sendCtrlAltDel();
    }
    if (action === "paste" && options.clipboard && !options.viewOnly) {
        if (options.renderer === "spice") {
            if (viewer.agent_connected) { pendingClipboard = value; viewer.send_clipboard_grab(); }
            else Spice.typeText(viewer, value);
        }
        else viewer.clipboardPasteFrom(value);
    }
    if (action === "fit") {
        options.fit = value;
        if (value) {
            const screen = document.getElementById("screen");
            screen.scrollLeft = 0;
            screen.scrollTop = 0;
        }
        if (options.renderer === "spice") fitSpice();
        else viewer.scaleViewport = value;
    }
    if (action === "resizeGuest") {
        options.resizeGuest = value;
        if (options.renderer === "spice") resizeSpiceGuest();
        else viewer.resizeSession = value;
    }
    if (action === "viewOnly") {
        options.viewOnly = value;
        if (options.renderer !== "spice") viewer.viewOnly = value;
    }
    if (action === "clipboard") { options.clipboard = value; if (!value) pendingClipboard = null; }
    if (action === "release") {
        document.activeElement?.blur();
        window.focus();
    }
};
// SPICE does not expose noVNC's viewOnly property. Stop all guest input at capture phase.
for (const name of ["keydown", "keyup", "mousedown", "mouseup", "mousemove", "wheel", "touchstart", "touchmove", "touchend"]) {
    document.addEventListener(name, event => {
        if (options?.viewOnly) { event.preventDefault(); event.stopImmediatePropagation(); }
    }, { capture: true, passive: false });
}
window.stopConsole = () => {
    stopped = true;
    clearTimeout(resizeTimer);
    pendingClipboard = null;
    if (options?.renderer === "spice") viewer?.stop(); else viewer?.disconnect();
    viewer = null;
    options = null;
    window.spice_connection = null;
    for (const socket of channels.values()) socket.close();
};
window.addEventListener("resize", () => {
    if (options?.renderer === "spice" && viewer) {
        fitSpice(); clearTimeout(resizeTimer);
        resizeTimer = setTimeout(resizeSpiceGuest, 200);
    }
});
send({ kind: "ready" });
