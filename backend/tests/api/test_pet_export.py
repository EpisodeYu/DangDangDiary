from datetime import date

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.models.deworming import Deworming, DewormingType
from app.models.pet import MemberRole, Pet, PetMember
from app.models.photo import Photo
from app.models.routine import Routine, RoutineType
from app.models.vaccination import Vaccination
from app.models.weight import Weight
from tests.api.test_pets import _create_pet, _login

pytestmark = pytest.mark.asyncio


async def test_export_all_records_and_original_manifest_without_pagination(client, test_engine):
    c, _ = client
    token, user_id = await _login(c, '13800139101')
    headers = {'Authorization': f'Bearer {token}'}
    pet = await _create_pet(c, headers, name='当当', birthday='2020-03-04')
    other = await _create_pet(c, headers, name='其他档案')
    async with async_sessionmaker(test_engine)() as db:
        profile = await db.get(Pet, pet['id'])
        profile.bath_cycle_days = 14
        profile.bath_reminder_enabled = True
        profile.combined_deworming_cycle_days = 30
        profile.combined_reminder_enabled = True
        for pet_id, count in [(pet['id'], 105), (other['id'], 1)]:
            for index in range(count):
                common = dict(pet_id=pet_id, user_id=user_id)
                day = date(2024, 1, index % 28 + 1)
                db.add_all([
                    Photo(**common, storage_key=f'{pet_id}/{index}.png', taken_at=day),
                    Weight(**common, weight_kg='4.25', recorded_at=day),
                    Deworming(**common, deworming_type=DewormingType.COMBINED, dewormed_at=day),
                    Vaccination(**common, vaccine_type='猫三联', vaccinated_at=day),
                    Routine(**common, routine_type=RoutineType.BATH, performed_at=day),
                ])
        await db.commit()
    response = await c.get(f"/pets/{pet['id']}/export", headers=headers)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data['schema_version'] == 1
    assert data['exported_at'].endswith('Z')
    assert data['pet']['name'] == '当当'
    assert data['pet']['birthday'] == '2020-03-04'
    assert data['pet']['bath_cycle_days'] == 14
    assert data['pet']['bath_reminder_enabled'] is True
    assert data['pet']['combined_deworming_cycle_days'] == 30
    assert data['pet']['combined_reminder_enabled'] is True
    assert 'invite_code' not in data['pet']
    assert len(data['photos']) == 105
    for row in data['photos']:
        assert row['pet_id'] == pet['id']
        assert row['storage_key'].endswith('.png')
        assert 'url' not in row
    for key, date_key in [('weights', 'recorded_at'), ('dewormings', 'dewormed_at'),
                          ('vaccinations', 'vaccinated_at'), ('routines', 'performed_at')]:
        rows = data['records'][key]
        assert len(rows) == 105
        assert all(row['pet_id'] == pet['id'] for row in rows)
        assert [(r[date_key], r['id']) for r in rows] == sorted(
            [(r[date_key], r['id']) for r in rows], reverse=True)


@pytest.mark.parametrize('role', list(MemberRole))
async def test_export_allowed_for_every_member(client, test_engine, role):
    c, _ = client
    token, _ = await _login(c, '13800139102')
    pet = await _create_pet(c, {'Authorization': f'Bearer {token}'})
    member_token, member_id = await _login(c, '13800139103')
    async with async_sessionmaker(test_engine)() as db:
        db.add(PetMember(pet_id=pet['id'], user_id=member_id, role=role))
        await db.commit()
    response = await c.get(f"/pets/{pet['id']}/export",
                           headers={'Authorization': f'Bearer {member_token}'})
    assert response.status_code == 200
    assert response.json()['photos'] == []
    assert all(rows == [] for rows in response.json()['records'].values())


async def test_export_selection_and_access(client):
    c, _ = client
    token, _ = await _login(c, '13800139104')
    headers = {'Authorization': f'Bearer {token}'}
    pet = await _create_pet(c, headers)
    url = f"/pets/{pet['id']}/export"
    photos = await c.get(url, params={'records': False}, headers=headers)
    assert photos.status_code == 200
    assert photos.json()['records'] is None
    records = await c.get(url, params={'photos': False}, headers=headers)
    assert records.status_code == 200
    assert records.json()['photos'] is None
    empty = await c.get(url, params={'photos': False, 'records': False}, headers=headers)
    assert empty.status_code == 400
    assert empty.json()['code'] == 'EXPORT_EMPTY_SELECTION'
    assert (await c.get(url)).status_code == 401
    other_token, _ = await _login(c, '13800139105')
    assert (await c.get(url, headers={'Authorization': f'Bearer {other_token}'})).status_code == 403
    assert (await c.get('/pets/999999/export', headers=headers)).status_code == 404
