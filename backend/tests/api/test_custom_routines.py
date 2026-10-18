from contextlib import ExitStack
from datetime import timedelta

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.models.pet import MemberRole, PetMember
from app.utils.time import today_cn
from tests.api.test_pets import _create_pet, _login
from tests.api.test_voice_intake import _multipart, _patch_upstream

pytestmark = pytest.mark.asyncio


async def setup(c):
    token, uid = await _login(c, '13800139901')
    h = {'Authorization': f'Bearer {token}'}
    pet = await _create_pet(c, h, name='当当')
    return pet['id'], h, uid


async def add(c, pet, h, name='刷牙'):
    response = await c.post(f'/pets/{pet}/routine-items', json={'name': name}, headers=h)
    assert response.status_code == 201, response.text
    return response.json()['routine_type']


async def test_defaults_quota_names_and_deleted_slot(client):
    c, _ = client
    pet, h, _ = await setup(c)
    state = (await c.get(f'/pets/{pet}/routine-status', headers=h)).json()
    assert [i['name'] for i in state['items']] == ['洗澡', '剪指甲']
    key = await add(c, pet, h, ' 刷牙 ')
    items = (await c.get(f'/pets/{pet}/routine-status', headers=h)).json()['items']
    assert items[-1]['name'] == '刷牙'
    assert items[-1]['cycle_days'] is None and items[-1]['reminder_enabled'] is False
    for name in (' ', '洗澡', '刷牙', 'a' * 21):
        r = await c.post(f'/pets/{pet}/routine-items', headers=h, json={'name': name})
        assert r.status_code in (400, 409), r.text
    for i in range(9):
        await add(c, pet, h, f'护理{i}')
    r = await c.post(f'/pets/{pet}/routine-items', headers=h, json={'name': '第十一项'})
    assert r.status_code == 400 and r.json()['code'] == 'ROUTINE_ITEM_LIMIT'
    assert (await c.delete(f'/pets/{pet}/routine-items/{key}', headers=h)).status_code == 204
    replacement = await add(c, pet, h)
    assert replacement != key


async def test_record_cycle_rename_delete_and_export(client):
    c, _ = client
    pet, h, _ = await setup(c)
    key = await add(c, pet, h)
    day = (today_cn() - timedelta(days=3)).isoformat()
    r = await c.post(f'/pets/{pet}/routines', headers=h, json={'routine_type': key, 'performed_at': day})
    assert r.status_code == 201, r.text
    record_id = r.json()['id']
    settings = {'items': [{'routine_type': key, 'cycle_days': 2, 'reminder_enabled': True}]}
    assert (await c.put(f'/pets/{pet}/routine-cycle', headers=h, json=settings)).status_code == 200
    item = (await c.get(f'/pets/{pet}/routine-status', headers=h)).json()['items'][-1]
    assert item['days_remaining'] == -1 and item['is_overdue'] is True
    assert (await c.put(f'/pets/{pet}/routine-items/{key}', headers=h, json={'name': '清洁牙齿'})).status_code == 200
    rows = (await c.get(f'/pets/{pet}/routines', headers=h)).json()['routines']
    assert rows[0]['routine_name'] == '清洁牙齿' and rows[0]['id'] == record_id
    assert (await c.delete(f'/pets/{pet}/routine-items/{key}', headers=h)).status_code == 204
    assert len((await c.get(f'/pets/{pet}/routine-status', headers=h)).json()['items']) == 2
    assert (await c.post(f'/pets/{pet}/routines', headers=h, json={'routine_type': key, 'performed_at': day})).status_code == 400
    assert (await c.put(f'/routines/{record_id}', headers=h, json={'routine_type': key, 'performed_at': day})).status_code == 200
    exported = (await c.get(f'/pets/{pet}/export', headers=h)).json()['records']
    assert exported['routines'][0]['routine_deleted'] is True
    assert exported['routines'][0]['routine_name'] == '清洁牙齿'
    archived = exported['routine_items'][-1]
    assert archived['deleted_at'] and archived['cycle_days'] == 2 and archived['reminder_enabled'] is False


async def test_scope_presets_and_cycle_transaction(client):
    c, _ = client
    pet, h, _ = await setup(c)
    other = (await _create_pet(c, h, name='其它宠物'))['id']
    key = await add(c, pet, h)
    await add(c, other, h)  # same display name belongs to a different definition
    for method, body in [('put', {'name': '改名'}), ('delete', None)]:
        request = getattr(c, method)
        kwargs = {'headers': h, **({'json': body} if body is not None else {})}
        assert (await request(f'/pets/{pet}/routine-items/bath', **kwargs)).status_code == 400
        assert (await request(f'/pets/{other}/routine-items/{key}', **kwargs)).status_code == 400
    r = await c.post(f'/pets/{other}/routines', headers=h, json={'routine_type': key, 'performed_at': today_cn().isoformat()})
    assert r.status_code == 400
    r = await c.put(f'/pets/{pet}/routine-cycle', headers=h, json={'items': [
        {'routine_type': key, 'cycle_days': 7, 'reminder_enabled': True},
        {'routine_type': 'unknown', 'cycle_days': 7, 'reminder_enabled': True},
    ]})
    assert r.status_code == 400
    item = (await c.get(f'/pets/{pet}/routine-status', headers=h)).json()['items'][-1]
    assert item['cycle_days'] is None and item['reminder_enabled'] is False


@pytest.mark.parametrize('role', [MemberRole.EDITOR, MemberRole.VIEWER])
async def test_member_permissions(client, test_engine, role):
    c, _ = client
    pet, h, _ = await setup(c)
    key = await add(c, pet, h)
    token, uid = await _login(c, '13800139902')
    mh = {'Authorization': f'Bearer {token}'}
    async with async_sessionmaker(test_engine)() as db:
        db.add(PetMember(pet_id=pet, user_id=uid, role=role))
        await db.commit()
    assert (await c.get(f'/pets/{pet}/routine-status', headers=mh)).status_code == 200
    requests = [
        await c.post(f'/pets/{pet}/routine-items', headers=mh, json={'name': '散步'}),
        await c.put(f'/pets/{pet}/routine-items/{key}', headers=mh, json={'name': '清洁牙齿'}),
        await c.put(f'/pets/{pet}/routine-cycle', headers=mh, json={'items': [{'routine_type': key, 'cycle_days': 7, 'reminder_enabled': True}]}),
        await c.post(f'/pets/{pet}/routines', headers=mh, json={'routine_type': key, 'performed_at': today_cn().isoformat()}),
        await c.delete(f'/pets/{pet}/routine-items/{key}', headers=mh),
    ]
    assert [r.status_code for r in requests] == ([201, 200, 200, 201, 204] if role == MemberRole.EDITOR else [403] * 5)


async def test_voice_custom_closed_set_and_deleted_draft(client):
    c, _ = client
    pet, h, _ = await setup(c)
    key = await add(c, pet, h)
    patches = _patch_upstream('今天给当当刷牙了', {'intent': 'routine', 'pet_name': '当当', 'routine_type': key, 'routine_at': 'today', 'confidence': 95})
    with ExitStack() as stack:
        mocks = [stack.enter_context(p) for p in patches]
        data, files = _multipart('custom-voice', default_pet_id=pet)
        response = await c.post('/voice/intake', headers=h, data=data, files=files)
        assert response.status_code == 200, response.text
        draft = response.json()
        assert draft['draft']['routine_type'] == key and draft['draft']['routine_name'] == '刷牙'
        choices = mocks[1].call_args.kwargs['known_routines']
        assert {'pet_name': '当当', 'routine_type': key, 'name': '刷牙'} in choices
    payload = {'request_id': draft['request_id'], 'intent': 'routine', 'payload': {'pet_id': pet, 'routine_type': key, 'routine_at': today_cn().isoformat()}}
    confirmed = await c.post('/voice/intake/confirm', headers=h, json=payload)
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()['entity']['routine_name'] == '刷牙'
    # Another pending draft cannot resurrect an item deleted after recognition.
    with ExitStack() as stack:
        for p in patches: stack.enter_context(p)
        data, files = _multipart('custom-voice-deleted', default_pet_id=pet)
        draft = (await c.post('/voice/intake', headers=h, data=data, files=files)).json()
    await c.delete(f'/pets/{pet}/routine-items/{key}', headers=h)
    payload['request_id'] = draft['request_id']
    assert (await c.post('/voice/intake/confirm', headers=h, json=payload)).status_code == 400


@pytest.mark.parametrize('value', ['custom_other_pet', '散步', 'grooming'])
async def test_voice_drops_uncreated_or_other_pet_item(client, value):
    c, _ = client
    pet, h, _ = await setup(c)
    await add(c, pet, h)
    patches = _patch_upstream('今天给当当散步了', {
        'intent': 'routine', 'pet_name': '当当', 'routine_type': value,
        'routine_at': 'today', 'confidence': 95,
    })
    with ExitStack() as stack:
        for patch in patches:
            stack.enter_context(patch)
        data, files = _multipart('invalid-custom-voice', default_pet_id=pet)
        response = await c.post('/voice/intake', headers=h, data=data, files=files)
    assert response.status_code == 200, response.text
    assert response.json()['draft']['routine_type'] is None
    assert 'routine_type' in response.json()['missing_fields']
