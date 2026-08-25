// The position of a target in a serial run, as the interface handles it.
//
// The sort itself is the server's business and is tested in tests/perl/order.t.
// What is decided HERE is what leaves the browser: which endpoint a row's
// number is written to, and that an empty field means "no answer given" rather
// than a request that comes back red.
//
//   node tests/js/order.test.js

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

claim('an empty field clears the order rather than being refused', () => {
    const { updmgr } = load(() => ({}));

    // 0 is how "after everything that has one" is spelled, and it is what
    // removes the stored value.
    assert.strictEqual(updmgr.parseOrder(''), 0);
    assert.strictEqual(updmgr.parseOrder('   '), 0);
    assert.strictEqual(updmgr.parseOrder(undefined), 0);
    assert.strictEqual(updmgr.parseOrder(null), 0);
});

claim('a number is taken as one, with the spaces around it', () => {
    const { updmgr } = load(() => ({}));

    assert.strictEqual(updmgr.parseOrder('10'), 10);
    assert.strictEqual(updmgr.parseOrder(' 7 '), 7);
    assert.strictEqual(updmgr.parseOrder('0'), 0);
    assert.strictEqual(updmgr.parseOrder(String(updmgr.MAX_ORDER)), updmgr.MAX_ORDER);
});

claim('anything that is not a plain number is refused before it is sent', () => {
    const { updmgr } = load(() => ({}));

    // undefined, not 0: a typo must not silently mean "clear it" - that is the
    // one wrong answer that looks like it worked.
    for (const bad of ['abc', '1.5', '-1', '1e3', '10 20', '٣', `${updmgr.MAX_ORDER + 1}`]) {
        assert.strictEqual(updmgr.parseOrder(bad), undefined, `refused: ${bad}`);
    }
});

claim('a container writes its order to its own node, a host to itself', () => {
    const { updmgr } = load(() => ({}));

    assert.strictEqual(
        updmgr.orderUrlFor({ type: 'lxc', vmid: 101, node: 'node-b' }, 'node-a'),
        '/nodes/node-b/lxc/101/updatemgr/order',
        "the row's own node wins over the tab's - a datacenter selection spans nodes",
    );
    assert.strictEqual(
        updmgr.orderUrlFor({ type: 'lxc', vmid: 101 }, 'node-a'),
        '/nodes/node-a/lxc/101/updatemgr/order',
        'and the node tab supplies the one its rows do not carry',
    );
    assert.strictEqual(
        updmgr.orderUrlFor({ type: 'node', node: 'node-b' }),
        '/nodes/node-b/updatemgr/order',
    );
    assert.strictEqual(
        updmgr.orderUrlFor({ type: 'lxc', vmid: 101 }),
        undefined,
        'and a row with no node at all is not written anywhere',
    );
});

done();
