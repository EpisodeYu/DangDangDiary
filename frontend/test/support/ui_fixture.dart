import 'package:dangdang_diary/models/health.dart';
import 'package:dangdang_diary/models/pet.dart';
import 'package:dangdang_diary/models/share.dart';
import 'package:dangdang_diary/models/timeline.dart';
import 'package:dangdang_diary/models/user.dart';
import 'package:dangdang_diary/providers/auth_provider.dart';
import 'package:dangdang_diary/providers/health_provider.dart';
import 'package:dangdang_diary/providers/pet_provider.dart';
import 'package:dangdang_diary/providers/share_provider.dart';
import 'package:dangdang_diary/providers/timeline_provider.dart';
import 'package:dangdang_diary/services/photo_service.dart';
import 'package:dangdang_diary/services/share_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Pet uiPet({String role = 'owner', bool longName = false}) => Pet.fromJson({
  'id': 7,
  'name': longName ? '一只名字特别特别长的毛孩子' : '当当',
  'pet_type': 'cat',
  'breed': '英国短毛猫',
  'birthday': '2023-06-01',
  'my_role': role,
  'is_owner': role == 'owner',
  'share_code_active': true,
  'created_at': '2024-01-01T00:00:00',
  'updated_at': '2024-01-01T00:00:00',
});

class UiPetList extends PetListNotifier {
  final List<Pet> pets;
  UiPetList(this.pets);
  @override
  Future<PetListResult> build() async =>
      PetListResult(page: 1, pageSize: 100, total: pets.length, pets: pets);
  @override
  Future<void> silentRefresh() async {}
  @override
  Future<void> refresh() async {
    state = AsyncData(await build());
  }
}

class UiAuth extends AuthNotifier {
  UiAuth() : super(autoCheck: false) {
    state = const AuthState(
      status: AuthStatus.authenticated,
      user: User(id: 1, phone: '13800000000', nickname: '当当的家人'),
    );
  }
}

class UiShares extends ShareService {
  @override
  Future<ShareCode?> getActiveCode(int petId) async => ShareCode(
    code: 'ABCD1234',
    expiresAt: DateTime.now().add(const Duration(hours: 20)),
    createdAt: DateTime.now(),
  );
  @override
  Future<List<SharedMember>> listMembers(int petId) async => [
    SharedMember(
      userId: 2,
      nickname: '一起照顾当当的家人',
      avatarUrl: null,
      role: PetRole.editor,
      joinedAt: DateTime(2026, 10, 1),
    ),
    SharedMember(
      userId: 3,
      nickname: '朋友',
      avatarUrl: null,
      role: PetRole.viewer,
      joinedAt: DateTime(2026, 10, 2),
    ),
  ];
}

class UiPhotos extends PhotoService {
  final List<TimelinePhoto> photos;
  UiPhotos([this.photos = const []]);
  @override
  Future<TimelineDatesResponse> getTimelineDates({
    List<int> petIds = const [],
  }) async => TimelineDatesResponse(
    months: photos.isEmpty
        ? []
        : [
            DateDistribution(
              date: '2026-10',
              label: '2026年10月',
              count: photos.length,
            ),
          ],
    dateRange: TimelineDateRange.empty,
  );
  @override
  Future<TimelineWindowResponse> getTimeline({
    List<int> petIds = const [],
    int limit = 40,
    String? cursor,
    String direction = 'older',
    String? anchorMonth,
  }) async => TimelineWindowResponse(
    groups: photos.isEmpty
        ? []
        : [
            TimelineGroup(
              date: '2026-10-18',
              label: '2026年10月18日',
              photos: photos,
            ),
          ],
    total: photos.length,
    limit: 40,
    hasMoreNewer: false,
    hasMoreOlder: false,
    dateRange: TimelineDateRange.empty,
  );
}

List<Override> uiOverrides({
  bool empty = false,
  bool longName = false,
  String role = 'owner',
  PhotoService? photos,
}) {
  final common = {
    'id': 1,
    'pet_id': 7,
    'user_id': 1,
    'created_at': '2026-10-18T00:00:00',
  };
  Map<String, dynamic> list(String key, Map<String, dynamic> row) => {
    key: empty ? [] : [row],
    'total': empty ? 0 : 1,
    'page': 1,
    'page_size': 20,
    'total_pages': empty ? 0 : 1,
  };
  return [
    authProvider.overrideWith((_) => UiAuth()),
    petListProvider.overrideWith(
      () => UiPetList(empty ? [] : [uiPet(role: role, longName: longName)]),
    ),
    shareServiceProvider.overrideWithValue(UiShares()),
    timelineProvider.overrideWith(
      (_) => TimelineNotifier(
        service: photos ?? UiPhotos(),
        filter: const TimelineFilter(petIds: []),
      ),
    ),
    weightListProvider.overrideWith(
      (_, id) async => WeightListResult.fromJson(
        list('weights', {
          ...common,
          'weight_kg': 4.25,
          'recorded_at': '2026-10-18',
        }),
      ),
    ),
    routineListProvider.overrideWith(
      (_, id) async => RoutineListResult.fromJson(
        list('routines', {
          ...common,
          'routine_type': 'bath',
          'performed_at': '2026-10-17',
        }),
      ),
    ),
    dewormingListProvider.overrideWith(
      (_, id) async => DewormingListResult.fromJson(
        list('dewormings', {
          ...common,
          'deworming_type': 'combined',
          'dewormed_at': '2026-10-16',
        }),
      ),
    ),
    vaccinationListProvider.overrideWith(
      (_, id) async => VaccinationListResult.fromJson(
        list('vaccinations', {
          ...common,
          'vaccine_type': longName ? '这是一条很长的自定义疫苗名称，用于验证内容完整换行展示' : '猫三联',
          'vaccinated_at': '2026-10-15',
        }),
      ),
    ),
    routineStatusProvider.overrideWith(
      (_, id) async => const RoutineStatus(
        bath: RoutineStatusItem(
          reminderEnabled: true,
          lastPerformedAt: '2026-10-17',
          cycleDays: 14,
          daysRemaining: 13,
        ),
        nailTrim: RoutineStatusItem(reminderEnabled: false),
        grooming: RoutineStatusItem(
          reminderEnabled: true,
          lastPerformedAt: '2026-10-01',
          cycleDays: 7,
          daysRemaining: -10,
          isOverdue: true,
        ),
      ),
    ),
    dewormingStatusProvider.overrideWith(
      (_, id) async => const DewormingStatus(
        internal: DewormingStatusItem(
          reminderEnabled: true,
          lastDewormedAt: '2026-10-01',
          cycleDays: 30,
          daysRemaining: 13,
        ),
        external: DewormingStatusItem(reminderEnabled: false),
        combined: DewormingStatusItem(reminderEnabled: false),
      ),
    ),
    vaccineTypesProvider.overrideWith((_, type) async => ['猫三联', '狂犬疫苗']),
  ];
}
