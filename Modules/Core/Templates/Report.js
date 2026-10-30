    // The report opens in Basetune's theme (set on <body> when the report
    // is generated). The toggle switches light/dark for this view only; the
    // choice is not stored, so every report opens the same way.
    const toggleBtn = document.getElementById('theme-toggle');
    toggleBtn.addEventListener('click', () => {
        document.body.classList.toggle('dark-mode');
    });

    const PAGE_SIZE = 100;
    const ALL_DATA  = JSON.parse(document.getElementById('report-data').textContent);

    // Platform dropdown: the platforms present in the data, in a fixed order
    // (Windows, macOS, iOS, Android, Linux), others after them.
    (function() {
        var order = ['Windows','macOS','iOS','Android','Linux'];
        var seen = {}, opts = [];
        for (var i = 0; i < ALL_DATA.length; i++) {
            var p = ALL_DATA[i].platform;
            if (p && !seen[p]) { seen[p] = true; opts.push(p); }
        }
        opts.sort(function(a,b){
            var ia = order.indexOf(a), ib = order.indexOf(b);
            if (ia < 0) ia = 99; if (ib < 0) ib = 99;
            return ia !== ib ? ia - ib : a.localeCompare(b);
        });
        var sel = document.getElementById('filterPlatform');
        for (var j = 0; j < opts.length; j++) {
            var o = document.createElement('option');
            o.value = opts[j]; o.textContent = opts[j];
            sel.appendChild(o);
        }
    })();

    // Policy dropdown: the source policies of the chosen platform (all
    // platforms: every policy). The current choice stays when it is still
    // in the list.
    function fillPolicies() {
        var platform = document.getElementById('filterPlatform').value;
        var sel  = document.getElementById('filterPolicy');
        var keep = sel.value;
        var seen = {}, opts = [];
        for (var i = 0; i < ALL_DATA.length; i++) {
            var r = ALL_DATA[i];
            if (platform && r.platform !== platform) continue;
            if (r.policy && !seen[r.policy]) { seen[r.policy] = true; opts.push(r.policy); }
        }
        opts.sort(function(a,b){ return a.localeCompare(b); });
        while (sel.options.length > 1) sel.remove(1);
        for (var j = 0; j < opts.length; j++) {
            var o = document.createElement('option');
            o.value = opts[j]; o.textContent = opts[j];
            sel.appendChild(o);
        }
        sel.value = seen[keep] ? keep : '';
    }
    fillPolicies();

    // Tiles count for the chosen platform (all platforms: the whole report),
    // so the number on a tile is the number of rows a click on it shows.
    var platformTotal = ALL_DATA.length;
    function updateTiles() {
        var platform = document.getElementById('filterPlatform').value;
        var c = { total:0, Match:0, Diff:0, Missing:0, Extra:0, Duplicate:0, Conflict:0 };
        for (var i = 0; i < ALL_DATA.length; i++) {
            var r = ALL_DATA[i];
            if (platform && r.platform !== platform) continue;
            c.total++;
            if (c[r.status] !== undefined) c[r.status]++;
            if (r.issue === 'Duplicate' || r.issue === 'Conflict') c[r.issue]++;
        }
        platformTotal = c.total;
        var set = function(cls, n) { var el = document.querySelector('.' + cls + ' .s-value'); if (el) el.textContent = n; };
        set('s-total', c.total);   set('s-match', c.Match);    set('s-diff', c.Diff);
        set('s-missing', c.Missing); set('s-extra', c.Extra);
        set('s-dup', c.Duplicate);   set('s-conflict', c.Conflict);
    }
    updateTiles();   // first fill of the tiles (all platforms)

    function onPlatformChange() {
        fillPolicies();
        updateTiles();
        applyFilters();
    }

    let filtered  = ALL_DATA.slice();
    let sortCol   = -1;
    let sortAsc   = true;
    let currentPage = 1;

    const statusBadge = {
        Match:   '<span class="badge val-match">Match</span>',
        Diff:    '<span class="badge val-diff">Diff</span>',
        Missing: '<span class="badge val-missing">Missing</span>',
        Extra:   '<span class="badge val-extra">Extra</span>'
    };
    const issueBadge = {
        Conflict:  function(n) { return '<span class="badge val-conflict">Conflict (' + n + ')</span>'; },
        Duplicate: function(n) { return '<span class="badge val-duplicate">Duplicate (' + n + ')</span>'; },
        None:      function()  { return '<span class="none-text">&#8212;</span>'; }
    };

    function esc(s) {
        return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }

    function renderPage() {
        const start  = (currentPage - 1) * PAGE_SIZE;
        const slice  = filtered.slice(start, start + PAGE_SIZE);
        const tbody  = document.getElementById('tableBody');

        var html = '';
        for (var i = 0; i < slice.length; i++) {
            var r   = slice[i];
            var idx = start + i;
            var hasTargets = r.targets && r.targets.length > 0;

            // Main row
            html += '<tr class="main-row" onclick="toggleDetail(' + idx + ')" id="row-' + idx + '">' +
                '<td class="col-policy" title="' + esc(r.policy) + '">' +
                    (hasTargets ? '<span class="expand-icon"><svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M4 2.5L7.5 6L4 9.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>' : '<span class="expand-icon" style="opacity:0"><svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M4 2.5L7.5 6L4 9.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>') +
                    esc(r.policy) + '</td>' +
                '<td class="col-setting">' + esc(r.setting) + '</td>' +
                '<td class="col-value">'   + esc(r.value)   + '</td>' +
                '<td class="col-status">' + (statusBadge[r.status] || esc(r.status)) + '</td>' +
                '<td class="col-issue">'  + (issueBadge[r.issue] ? issueBadge[r.issue](r.tcount) : esc(r.issue)) + '</td>' +
                '</tr>';

            // Detail rows (hidden by default): target policy under Policy +
            // Setting, target value under Source Value, so they line up.
            var dc = 'detail-row hidden detail-' + idx;
            if (hasTargets) {
                html += '<tr class="' + dc + ' dt-head">' +
                    '<td colspan="2" class="dt-policy">Target Policy</td><td colspan="3">Target Value</td></tr>';
                for (var j = 0; j < r.targets.length; j++) {
                    var t = r.targets[j];
                    html += '<tr class="' + dc + ' dt-item">' +
                        '<td colspan="2" class="dt-policy">' + esc(t.name) + '</td>' +
                        '<td colspan="3">' + esc(t.value) + '</td></tr>';
                }
                html += '<tr class="' + dc + ' dt-end"><td colspan="5"></td></tr>';
            } else {
                html += '<tr class="' + dc + ' dt-last">' +
                    '<td colspan="5" class="dt-empty">No matching target policies found.</td></tr>';
            }
        }

        tbody.innerHTML = html;

        const total = filtered.length;
        const pages = Math.ceil(total / PAGE_SIZE) || 1;

        document.getElementById('rowCount').textContent =
            total + ' of ' + platformTotal + ' settings visible';

        renderPagination(pages);
    }

    function toggleDetail(idx) {
        var mainRow   = document.getElementById('row-'   + idx);
        var detailRows = document.querySelectorAll('tr.detail-' + idx);
        if (!detailRows.length) return;
        var isOpen = !detailRows[0].classList.contains('hidden');
        for (var k = 0; k < detailRows.length; k++) detailRows[k].classList.toggle('hidden', isOpen);
        mainRow.classList.toggle('expanded', !isOpen);
    }

    function renderPagination(pages) {
        const el = document.getElementById('pagination');
        if (pages <= 1) { el.innerHTML = ''; return; }

        const prev = currentPage - 1;
        const next = currentPage + 1;

        var btns = '';
        btns += '<button tabindex="-1" onclick="goPage(1)"'       + (currentPage===1     ? ' disabled' : '') + '>&#171; First</button>';
        btns += '<button tabindex="-1" onclick="goPage(' + prev + ')"' + (currentPage===1 ? ' disabled' : '') + '>&#8249; Prev</button>';

        var range = 3;
        for (var p = Math.max(1, currentPage - range); p <= Math.min(pages, currentPage + range); p++) {
            btns += '<button tabindex="-1" onclick="goPage(' + p + ')"' + (p === currentPage ? ' class="active"' : '') + '>' + p + '</button>';
        }

        btns += '<button tabindex="-1" onclick="goPage(' + next   + ')"' + (currentPage===pages ? ' disabled' : '') + '>Next &#8250;</button>';
        btns += '<button tabindex="-1" onclick="goPage(' + pages  + ')"' + (currentPage===pages ? ' disabled' : '') + '>Last &#187;</button>';
        btns += '<span class="page-info">Page ' + currentPage + ' of ' + pages + '</span>';

        el.innerHTML = btns;
    }

    function goPage(p) {
        const pages = Math.ceil(filtered.length / PAGE_SIZE) || 1;
        currentPage = Math.max(1, Math.min(p, pages));
        renderPage();
        window.scrollTo({ top: 0, behavior: 'smooth' });
    }

    // A tile keeps the chosen platform; policy and search are cleared.
    function filterByCard(status, issue) {
        document.getElementById('filterStatus').value = status;
        document.getElementById('filterIssue').value  = issue;
        document.getElementById('filterPolicy').value = '';
        document.getElementById('search').value = '';
        applyFilters();
    }

    // The highlight is derived from the filter state, not set on click.
    // Otherwise a tile would stay highlighted after choosing something else
    // in the dropdowns or the search field.
    //
    // A tile is only active when the view is exactly what that tile shows:
    // a single status or a single issue, without search text and without
    // policy filter. The platform filter does not count: the tiles count for
    // the chosen platform themselves. A combination highlights nothing,
    // because no single tile covers it.
    function syncCards() {
        document.querySelectorAll('.stat-card').forEach(function(c) {
            c.classList.remove('active');
        });

        var search = document.getElementById('search').value.trim();
        var status = document.getElementById('filterStatus').value;
        var issue  = document.getElementById('filterIssue').value;
        var policy = document.getElementById('filterPolicy').value;

        if (search || policy) { return; }
        if (status && issue)  { return; }

        var cls;
        if (!status && !issue) {
            cls = 's-total';
        } else {
            var map = { 'Match':'s-match', 'Diff':'s-diff', 'Missing':'s-missing',
                        'Extra':'s-extra', 'Duplicate':'s-dup', 'Conflict':'s-conflict' };
            cls = map[status || issue];
        }

        if (!cls) { return; }
        var el = document.querySelector('.' + cls);
        if (el) { el.classList.add('active'); }
    }

    function applyFilters() {
        const search = document.getElementById('search').value.toLowerCase();
        const status = document.getElementById('filterStatus').value;
        const issue  = document.getElementById('filterIssue').value;
        const policy = document.getElementById('filterPolicy').value;
        const platform = document.getElementById('filterPlatform').value;

        // The search also matches the target policies of a row (the detail
        // rows), for every status: a policy name finds every row it is in,
        // as source or as target (Extra rows have only targets). The Policy
        // dropdown filters on the source policy only.
        function targetPolicyHit(r) {
            if (!r.targets) return false;
            for (var k = 0; k < r.targets.length; k++) {
                if ((r.targets[k].name || '').toLowerCase().includes(search)) return true;
            }
            return false;
        }

        filtered = ALL_DATA.filter(function(r) {
            return (!search || (r.policy  || '').toLowerCase().includes(search) ||
                               (r.setting || '').toLowerCase().includes(search) ||
                               (r.value   || '').toLowerCase().includes(search) ||
                               targetPolicyHit(r))
                && (!status || r.status === status)
                && (!issue  || r.issue  === issue)
                && (!policy || r.policy === policy)
                && (!platform || r.platform === platform);
        });

        if (sortCol >= 0) applySort(false);

        syncCards();
        currentPage = 1;
        renderPage();
    }

    const sortKeys = ['policy','setting','value','status','issue'];

    function sortTable(col) {
        if (sortCol === col) { sortAsc = !sortAsc; } else { sortCol = col; sortAsc = true; }

        document.querySelectorAll('th').forEach((th, i) => {
            th.classList.remove('sorted-asc','sorted-desc');
            if (i === col) th.classList.add(sortAsc ? 'sorted-asc' : 'sorted-desc');
        });

        // applySort(false): sort without drawing. The renderPage below draws
        // once, with currentPage already reset to 1.
        applySort(false);
        currentPage = 1;
        renderPage();
    }

    function applySort(rerender) {
        const key = sortKeys[sortCol];
        filtered.sort((a, b) => {
            const ta = (a[key] ?? '').toLowerCase();
            const tb = (b[key] ?? '').toLowerCase();
            // Policy: Extra rows (no policy) always at the bottom.
            if (key === 'policy' && (ta === '') !== (tb === '')) return ta === '' ? 1 : -1;
            let c = ta.localeCompare(tb);
            // Issue: same type (Conflict / Duplicate) -> sort on the number
            // of target policies, so Conflict (2) comes before Conflict (8).
            if (c === 0 && key === 'issue') c = (Number(a.tcount) || 0) - (Number(b.tcount) || 0);
            return sortAsc ? c : -c;
        });
        if (rerender) renderPage();
    }

    applyFilters();

    // ── Resizable columns ────────────────────────────────────────────────
    // Fixed layout, so expanding a row or paging never makes columns jump.
    //   Status, Issue : fixed 130px (they only hold a badge)
    //   Policy, Setting: % of the table width (default 20% / 38%), resizable
    //   Source Value  : takes the rest
    // Percentages, so the columns grow and shrink with the window.
    // Drag a border (Policy|Setting, Setting|Source Value or Source Value|
    // Status) anywhere in the table, header or rows. Status and Issue keep
    // their width: making Source Value wider takes the space from Setting,
    // then Policy. Double-click a border to reset. Every report opens with
    // the default layout (widths are not stored).
    (function () {
        var table = document.getElementById('mainTable');
        var ths   = Array.prototype.slice.call(table.querySelectorAll('thead th'));
        var GRAB  = 7;          // px either side of a border that starts a drag
        var FIXED = 130;        // Status / Issue
        var MIN   = [120, 200, 150];   // Policy, Setting, Source Value
        var DEF   = [0.20, 0.38];      // default Policy / Setting share of the table
        var drag  = null;

        function tw() { return table.getBoundingClientRect().width || 1; }
        function px(i) { return ths[i].getBoundingClientRect().width; }
        function room() { return tw() - 2 * FIXED; }   // for the 3 text columns
        // Clamp Policy/Setting (px) so every text column keeps its minimum.
        function clamp(p, st) {
            var r = room();
            p  = Math.max(MIN[0], Math.min(p,  r - MIN[1] - MIN[2]));
            st = Math.max(MIN[1], Math.min(st, r - p - MIN[2]));
            return [p, st];
        }
        function apply(p, st) {
            var c = clamp(p, st), t = tw();
            ths[0].style.width = (c[0] * 100 / t).toFixed(3) + '%';
            ths[1].style.width = (c[1] * 100 / t).toFixed(3) + '%';
            ths[2].style.width = '';
            ths[3].style.width = FIXED + 'px';
            ths[4].style.width = FIXED + 'px';
            table.classList.add('resized');
        }
        function freeze() {
            // Default layout: fixed percentages of the table width.
            apply(tw() * DEF[0], tw() * DEF[1]);
        }
        function reset() { freeze(); }
        // 0 = Policy|Setting, 1 = Setting|Source Value, 2 = Source Value|Status.
        function borderAt(x) {
            for (var i = 0; i < 3; i++) {
                if (Math.abs(ths[i].getBoundingClientRect().right - x) <= GRAB) return i;
            }
            return -1;
        }

        function hover(i) { table.classList.toggle('near-border', i >= 0); }

        table.addEventListener('mousemove', function (e) {
            if (drag) return;
            hover(borderAt(e.clientX));
        });
        table.addEventListener('mouseleave', function () { if (!drag) hover(-1); });

        table.addEventListener('mousedown', function (e) {
            if (e.button !== 0) return;
            var i = borderAt(e.clientX);
            if (i < 0) return;
            e.preventDefault(); e.stopPropagation();
            drag = { i: i, x: e.clientX, p: px(0), s: px(1), v: px(2) };
            document.body.classList.add('col-resizing');
            var r = ths[i].querySelector('.col-resizer'); if (r) r.classList.add('active');
        });
        document.addEventListener('mousemove', function (e) {
            if (!drag) return;
            var dx = e.clientX - drag.x;
            if (drag.i === 0) {
                // Move the Policy|Setting border: Setting gives/takes the space.
                var pair = drag.p + drag.s;
                var p = Math.max(MIN[0], Math.min(drag.p + dx, pair - MIN[1]));
                apply(p, pair - p);
            } else if (drag.i === 1) {
                // Move the Setting|Source Value border: Source Value takes the rest.
                apply(drag.p, drag.s + dx);
            } else {
                // Move the Source Value|Status border: Status/Issue stay put,
                // so Setting (then Policy) gives or takes the space.
                var v    = Math.max(MIN[2], Math.min(drag.v + dx, room() - MIN[0] - MIN[1]));
                var rest = room() - v;                 // for Policy + Setting
                var st   = Math.max(MIN[1], rest - drag.p);
                apply(rest - st, st);
            }
        });
        document.addEventListener('mouseup', function () {
            if (!drag) return;
            var r = ths[drag.i].querySelector('.col-resizer'); if (r) r.classList.remove('active');
            drag = null;
            document.body.classList.remove('col-resizing');
            hover(-1);
            // The mouseup after a drag counts as a click (= sort a column or
            // open a row). Swallow that one click.
            function swallow(ce) {
                ce.stopPropagation(); ce.preventDefault();
                window.removeEventListener('click', swallow, true);
            }
            window.addEventListener('click', swallow, true);
            setTimeout(function () { window.removeEventListener('click', swallow, true); }, 300);
        });
        table.addEventListener('dblclick', function (e) {
            if (borderAt(e.clientX) < 0) return;
            e.preventDefault(); e.stopPropagation();
            reset();
        }, true);

        // Visual marker on the two resizable header borders.
        [0, 1, 2].forEach(function (i) {
            var h = document.createElement('div');
            h.className = 'col-resizer';
            h.title = 'Drag to resize. Double-click to reset';
            ths[i].appendChild(h);
        });

        // Smaller window: keep the minimum widths (Setting/Policy shrink first).
        window.addEventListener('resize', function () {
            if (table.classList.contains('resized')) apply(px(0), px(1));
        });

        // Start: default layout.
        freeze();
    })();

    // Tiles are reachable with Tab: Enter or Space filters, like a click.
    document.addEventListener('keydown', function (e) {
        var card = e.target && e.target.closest ? e.target.closest('.stat-card') : null;
        if (!card) return;
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); card.click(); }
    });
