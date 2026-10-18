// Small UI hooks; ESW owns event ordering, DOM updates, and reconnects.
import { connectLiveViews } from '/_live/bookmarks/assets/esw-live.js';

for (const client of connectLiveViews()) {
    const root = client.root;
    root.dataset.bookmarksClient = '';
    let nextFocus;
    let restoreFocus = false;
    root.addEventListener('submit', event => {
        const form = event.target.closest('form[esw-submit="read"]');
        if (!form) return;
        restoreFocus = form.contains(document.activeElement);
        const buttons = [...root.querySelectorAll('.read-toggle')];
        const index = buttons.indexOf(form.querySelector('.read-toggle'));
        nextFocus = (buttons[index + 1] ?? buttons[index - 1])?.closest('li')?.id;
    }, true);
    root.addEventListener('esw:error', () => { root.dataset.readError = ''; });
    root.addEventListener('esw:update', event => {
        if (!event.detail.eventID) return;
        delete root.dataset.readError;
        if (document.activeElement === document.body && restoreFocus) {
            const next = document.getElementById(nextFocus)?.querySelector('.read-toggle');
            (next ?? root.querySelector('#queue-heading'))?.focus();
        }
        nextFocus = undefined;
        restoreFocus = false;
    });
}
