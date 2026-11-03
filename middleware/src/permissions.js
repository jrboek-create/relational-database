// The permission list (decided 3 Nov 2026). Everyone signed in always sees: Find a course, the course catalog, and in
// course detail: course identity, organizational context, curriculum, and instructional design and development.
// Everything below is a checkbox per role. An item counts only if it AND every group above it are ticked
// ("group off hides everything in it"). The Admin role always has everything.
export const SURVEY_QUESTIONS = {
  new: [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 13],
  old: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 14, 15, 16, 17, 19, 20, 21, 22, 23, 24, 26, 28]
};

export const PERMISSIONS = [
  { key: "performance", label: "Course performance", parent: null },
  { key: "performance.grades", label: "Grades", parent: "performance" },
  { key: "performance.enrollment", label: "Enrollment", parent: "performance" },
  { key: "performance.dfwi", label: "DFWI", parent: "performance" },
  { key: "feedback", label: "Feedback and evaluation", parent: null },
  { key: "feedback.faculty_survey", label: "Faculty survey results", parent: "feedback" },
  { key: "feedback.student_survey", label: "Student survey results", parent: "feedback" },
  { key: "feedback.student_survey.new", label: "New survey", parent: "feedback.student_survey" },
  ...SURVEY_QUESTIONS.new.map((n) => ({ key: `feedback.student_survey.new.q${n}`, label: `Question ${n}`, parent: "feedback.student_survey.new", survey: "NEW", question: n })),
  { key: "feedback.student_survey.old", label: "Old survey", parent: "feedback.student_survey" },
  ...SURVEY_QUESTIONS.old.map((n) => ({ key: `feedback.student_survey.old.q${n}`, label: `Question ${n}`, parent: "feedback.student_survey.old", survey: "OLD", question: n })),
  { key: "feedback.ai_production", label: "AI in this course", parent: "feedback" },
  { key: "feedback.integrations", label: "Integrations", parent: "feedback" },
  { key: "feedback.redeveloped", label: "Redeveloped course feedback", parent: "feedback" },
  { key: "feedback.observations", label: "Faculty observations", parent: "feedback" }
];

const byKey = new Map(PERMISSIONS.map((p) => [p.key, p]));

// Keys that are in effect: ticked, and every group above them ticked. Unknown keys are ignored.
export function effectivePermissions(ticked, isAdmin) {
  if (isAdmin) return new Set(byKey.keys());
  const set = new Set(ticked);
  const ok = (key) => {
    for (let p = byKey.get(key); p; p = p.parent ? byKey.get(p.parent) : null) {
      if (!set.has(p.key)) return false;
    }
    return true;
  };
  return new Set([...byKey.keys()].filter(ok));
}

// Which permission each course section needs (null = everyone signed in).
export const SECTION_PERMISSION = {
  "grades": "performance.grades",
  "enrollment": "performance.enrollment",
  "dfwi": "performance.dfwi",
  "faculty-survey": "feedback.faculty_survey",
  "student-survey": "feedback.student_survey",
  "student-survey/questions": "feedback.student_survey",     // and then each question is checked on its own
  "instructional-design-development": null,
  "ai-production": "feedback.ai_production",
  "integrations": "feedback.integrations",
  "redeveloped": "feedback.redeveloped",
  "observations": "feedback.observations"
};

export const questionKey = (surveyVersion, questionNumber) =>
  `feedback.student_survey.${String(surveyVersion).toLowerCase()}.q${Number(questionNumber)}`;
