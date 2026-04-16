import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/pet.dart';
import 'api_client.dart';

class PetService {
  final Dio _dio = ApiClient().dio;

  Future<PetListResult> getPets({int page = 1, int pageSize = 20}) async {
    final resp = await _dio.get(
      '/pets',
      queryParameters: {'page': page, 'page_size': pageSize},
    );
    return PetListResult.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<Pet> getPetDetail(int petId) async {
    final resp = await _dio.get('/pets/$petId');
    return Pet.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<Pet> createPet({
    required String name,
    required String petType,
    String? breed,
    String? birthday,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'pet_type': petType,
    };
    if (breed != null && breed.isNotEmpty) body['breed'] = breed;
    if (birthday != null && birthday.isNotEmpty) body['birthday'] = birthday;

    final resp = await _dio.post('/pets', data: body);
    return Pet.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<Pet> updatePet(int petId, {
    String? name,
    String? breed,
    String? birthday,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (breed != null) body['breed'] = breed;
    if (birthday != null) body['birthday'] = birthday;

    final resp = await _dio.put('/pets/$petId', data: body);
    return Pet.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<Pet> uploadAvatar(
    int petId,
    Uint8List bytes,
    String filename, {
    ProgressCallback? onSendProgress,
  }) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final resp = await _dio.post(
      '/pets/$petId/avatar',
      data: formData,
      options: Options(contentType: 'multipart/form-data'),
      onSendProgress: onSendProgress,
    );
    return Pet.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<void> deletePet(int petId) async {
    await _dio.delete('/pets/$petId');
  }
}
