// The permission list (decided 3 Nov 2026). Everyone signed in always sees: Find a course, the course catalog, and in
// course detail: course identity, organizational context, curriculum, and instructional design and development.
// Everything below is a checkbox per role. An item counts only if it AND every group above it are ticked
// ("group off hides everything in it"). The Admin role always has everything.
export const SURVEY_QUESTIONS = {
  new: [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 13],
  old: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 14, 15, 16, 17, 19, 20, 21, 22, 23, 24, 26, 28]
};

// Question wording (from the student survey data), shown on the Admin page next to each question's checkbox.
export const QUESTION_TITLES = {
  new: {
    1: "Learning Environment: The instructor encouraged an atmosphere in which I felt comfortable participating.",
    2: "Connection to Application: The instructor demonstrated how the course was relevant to my future academic, professional, and/or personal success.",
    3: "Engagement/Active Learning: The instructor kept me engaged by using various teaching methods (e.g. lectures, discussions, case studies, and other course activities).",
    4: "Delivery and Presentation: The instructor presented course material in a clear and organized manner that supported my learning.",
    5: "Responsiveness and Communication: The instructor was readily available and gave me timely and specific feedback.",
    6: "Instructional Assessment: The instructor clearly communicated expectations on graded activities by providing me with rubrics, criteria, and/or examples.",
    7: "Overall Teaching Effectiveness: Rate your instructor’s overall teaching effectiveness.",
    9: "The course was well-structured with clear instructions, activities, and grading criteria that supported my learning.",
    10: "The variety of instructional materials in this course enhanced my learning.",
    11: "The design and progression of learning activities helped me feel confident in applying what I learned.",
    13: "Based on my overall experience, I would recommend this course to another student."
  },
  old: {
    1: "The instructor exhibited expertise in the course subject matter.",
    2: "The instructor used a variety of methods to communicate with the class. (e.g. email, announcements, etc.)",
    3: "The instructor was readily available for questions and assistance outside the classroom.",
    4: "The instructor provided timely feedback on my assignments and progress.",
    5: "The instructor provided meaningful feedback on my assignments and progress.",
    6: "The instructor kept the class actively engaged with the subject matter and each other.",
    7: "The instructor demonstrated the relevance of the curriculum to real-world situations.",
    8: "My overall impression of the instructor is positive.",
    9: "How likely is it that you would recommend this instructor to a fellow student?",
    11: "The delivery mode (e.g. Classroom, Online, EagleVision, etc.) used in this course was my most preferred delivery mode.",
    12: "My overall impression of this delivery mode (e.g. Classroom, Online, EagleVision, etc.) is positive.",
    14: "The learning objectives were clearly stated throughout this course.",
    15: "Quizzes and examinations were fair tests of the learning objectives and materials in the course.",
    16: "The grading criteria were explicit and easy to understand.",
    17: "Instructions for course activities and assignments were clear.",
    19: "The workload in this course was well-distributed throughout the term.",
    20: "This course used a variety of instructional methods, materials, and media.",
    21: "The textbook and/or assigned readings were relevant and supported the learning objectives.",
    22: "Graded assignments contributed to my knowledge of the course material and understanding of the subject.",
    23: "Overall, this course met my expectations for the quality of an ERAU course.",
    24: "Tuition paid for this course was a worthwhile investment.",
    26: "Rate this instructor's overall teaching effectiveness:",
    28: "Rate the overall quality of this course:"
  }
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
  ...SURVEY_QUESTIONS.new.map((n) => ({ key: `feedback.student_survey.new.q${n}`, label: `Question ${n}`, title: QUESTION_TITLES.new[n], parent: "feedback.student_survey.new", survey: "NEW", question: n })),
  { key: "feedback.student_survey.old", label: "Old survey", parent: "feedback.student_survey" },
  ...SURVEY_QUESTIONS.old.map((n) => ({ key: `feedback.student_survey.old.q${n}`, label: `Question ${n}`, title: QUESTION_TITLES.old[n], parent: "feedback.student_survey.old", survey: "OLD", question: n })),
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
