import 'package:serverpod/database.dart';
import 'package:serverpod_test_server/src/generated/protocol.dart';
import 'package:serverpod_test_server/test_util/test_serverpod.dart';
import 'package:test/test.dart';

void main() async {
  var session = await IntegrationTestServer().session();

  group('Given entities with many to many relation', () {
    tearDown(() async {
      await Enrollment.db
          .deleteWhere(session, where: (_) => Constant.bool(true));
      await Student.db.deleteWhere(session, where: (_) => Constant.bool(true));
      await Course.db.deleteWhere(session, where: (_) => Constant.bool(true));
    });

    test(
        'when deleting entities filtered by every many relation then result is as expected',
        () async {
      var students = await Student.db.insert(session, [
        Student(name: 'Alex'),
        Student(name: 'Viktor'),
        Student(name: 'Isak'),
        Student(name: 'Lisa'),
      ]);
      var courses = await Course.db.insert(session, [
        Course(name: 'Level 1: Math'),
        Course(name: 'Level 1: English'),
        Course(name: 'Level 1: History'),
        Course(name: 'Level 2: Math'),
        Course(name: 'Level 2: English'),
        Course(name: 'Level 2: History'),
      ]);
      await Enrollment.db.insert(session, [
        // Alex is enrolled in Level 1 Math and Level 1 English
        Enrollment(studentId: students[0].id!, courseId: courses[0].id!),
        Enrollment(studentId: students[0].id!, courseId: courses[1].id!),
        // Isak is enrolled in Level 1 English and Level 2 Math
        Enrollment(studentId: students[2].id!, courseId: courses[1].id!),
        Enrollment(studentId: students[2].id!, courseId: courses[3].id!),
        // Lisa is enrolled in Level 2 Math, Level 2 English and Level 2 History
        Enrollment(studentId: students[3].id!, courseId: courses[3].id!),
        Enrollment(studentId: students[3].id!, courseId: courses[4].id!),
        Enrollment(studentId: students[3].id!, courseId: courses[5].id!),
      ]);

      var deletedStudentIds = await Student.db.deleteWhere(
        session,
        // All students enrolled to only level 2 courses.
        where: (s) =>
            s.enrollments.every((e) => e.course.name.ilike('level 2:%')),
      );

      expect(deletedStudentIds, [
        students[3].id, // Lisa
      ]);
    });

    test(
        'when deleting entities filtered by every many relation in combination with other filter then result is as expected',
        () async {
      var students = await Student.db.insert(session, [
        Student(name: 'Alex'),
        Student(name: 'Viktor'),
        Student(name: 'Isak'),
        Student(name: 'Lisa'),
      ]);
      var courses = await Course.db.insert(session, [
        Course(name: 'Level 1: Math'),
        Course(name: 'Level 1: English'),
        Course(name: 'Level 1: History'),
        Course(name: 'Level 2: Math'),
        Course(name: 'Level 2: English'),
        Course(name: 'Level 2: History'),
      ]);
      await Enrollment.db.insert(session, [
        // Alex is enrolled in Level 1 English
        Enrollment(studentId: students[0].id!, courseId: courses[2].id!),
        // Viktor is enrolled in Level 1 Math and Level 1 History
        Enrollment(studentId: students[1].id!, courseId: courses[0].id!),
        Enrollment(studentId: students[1].id!, courseId: courses[2].id!),
        // Lisa is enrolled in Level 1 and Level 2 Math
        Enrollment(studentId: students[3].id!, courseId: courses[0].id!),
        Enrollment(studentId: students[3].id!, courseId: courses[3].id!),
      ]);

      var deletedStudentIds = await Student.db.deleteWhere(
        session,
        // All students enrolled to only math courses or is named Alex.
        where: (s) =>
            (s.enrollments.every((e) => e.course.name.ilike('%math%'))) |
            s.name.equals('Alex'),
      );

      expect(deletedStudentIds, hasLength(2));
      expect(
          deletedStudentIds,
          containsAll([
            students[0].id, // Alex
            students[3].id, // Lisa
          ]));
    });

    test(
        'when deleting entities filtered by multiple every many relation then result is as expected',
        () async {
      var students = await Student.db.insert(session, [
        Student(name: 'Alex'),
        Student(name: 'Viktor'),
        Student(name: 'Isak'),
        Student(name: 'Lisa'),
        Student(name: 'Anna'),
      ]);
      var courses = await Course.db.insert(session, [
        Course(name: 'Level 1: Math'),
        Course(name: 'Level 1: English'),
        Course(name: 'Level 1: History'),
        Course(name: 'Level 2: Math'),
        Course(name: 'Level 2: English'),
        Course(name: 'Level 2: History'),
      ]);
      await Enrollment.db.insert(session, [
        // Alex is enrolled in Level 1 Math and Level 1 English
        Enrollment(studentId: students[0].id!, courseId: courses[0].id!),
        Enrollment(studentId: students[0].id!, courseId: courses[1].id!),
        // Isak is enrolled in Level 1 Math
        Enrollment(studentId: students[2].id!, courseId: courses[0].id!),
        // Lisa is enrolled in Level 2 Math, Level 2 English and Level 2 History
        Enrollment(studentId: students[3].id!, courseId: courses[3].id!),
        Enrollment(studentId: students[3].id!, courseId: courses[4].id!),
        Enrollment(studentId: students[3].id!, courseId: courses[5].id!),
      ]);

      var deletedStudentIds = await Student.db.deleteWhere(
        session,
        // All students enrolled to only level 2 courses or only math courses.
        where: (s) =>
            (s.enrollments.every((e) => e.course.name.ilike('level 2:%'))) |
            (s.enrollments.every((e) => e.course.name.ilike('%math%'))),
      );

      expect(deletedStudentIds, hasLength(2));
      expect(
          deletedStudentIds,
          containsAll([
            students[2].id, // Isak
            students[3].id, // Lisa
          ]));
    });
  });
}
