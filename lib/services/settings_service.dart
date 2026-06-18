import 'package:shared_preferences/shared_preferences.dart';

Future<int> getMonthlyBudget() async => (await SharedPreferences.getInstance()).getInt('monthly_budget') ?? 0;
Future<void> setMonthlyBudget(int v) async => (await SharedPreferences.getInstance()).setInt('monthly_budget', v);