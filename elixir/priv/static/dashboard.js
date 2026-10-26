(function () {
  function formatLocalTime(element) {
    var raw = element.dataset.localTime;
    var parsed = raw ? new Date(raw) : null;

    if (!parsed || Number.isNaN(parsed.getTime())) return;

    element.textContent = new Intl.DateTimeFormat(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      second: "2-digit",
      hour12: true,
      timeZoneName: "short"
    }).format(parsed);
  }

  window.SymphonyHooks = window.SymphonyHooks || {};
  window.SymphonyHooks.LocalTime = {
    mounted: function () {
      formatLocalTime(this.el);
    },
    updated: function () {
      formatLocalTime(this.el);
    }
  };

  window.SymphonyHooks.PersistentDisclosure = {
    mounted: function () {
      this.wasOpen = this.el.open;
      this.rememberState = function () {
        this.wasOpen = this.el.open;
      }.bind(this);
      this.el.addEventListener("toggle", this.rememberState);
    },
    beforeUpdate: function () {
      this.wasOpen = this.el.open;
    },
    updated: function () {
      this.el.open = this.wasOpen;
    },
    destroyed: function () {
      this.el.removeEventListener("toggle", this.rememberState);
    }
  };

  window.SymphonyHooks.CopySuggestedPrompt = {
    mounted: function () {
      this.copySuggestedPrompt = async function (event) {
        var button = event.target.closest("button[data-copy-suggested-prompt]");
        if (!button || !this.el.contains(button) || this.copying) return;
        event.preventDefault();
        var status = this.el.querySelector(".copy-note");
        this.copying = true;
        button.disabled = true;
        try {
          var bytes = Uint8Array.from(atob(button.dataset.promptBase64), function (character) { return character.charCodeAt(0); });
          var prompt = new TextDecoder("utf-8", {fatal: true, ignoreBOM: true}).decode(bytes);
          await navigator.clipboard.writeText(prompt);
          status.textContent = "Copied. Open chat to paste and review; nothing has been sent.";
        } catch (_error) {
          status.textContent = "Copy unavailable. Nothing has been sent.";
        } finally {
          this.copying = false;
          button.disabled = false;
        }
      }.bind(this);
      this.el.addEventListener("click", this.copySuggestedPrompt);
    },
    destroyed: function () {
      this.el.removeEventListener("click", this.copySuggestedPrompt);
    }
  };
})();
