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
})();
