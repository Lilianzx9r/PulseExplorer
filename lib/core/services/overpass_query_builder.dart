class OverpassQueryBuilder {
  final List<String> _filters=[];
  int timeout=25;
  int maxSize=536870912;

  void addFilter(String filter)=>_filters.add(filter);

  String build(String bbox){
    final b=StringBuffer()
      ..writeln('[out:json][timeout:$timeout][maxsize:$maxSize];(');
    for(final f in _filters){
      b.writeln('node$f($bbox);');
      b.writeln('way$f($bbox);');
      b.writeln('relation$f($bbox);');
    }
    b.writeln(');out center tags;');
    return b.toString();
  }
}
